//! Luau create→set→write→reopen→read-back via CPSL sandbox + real cells_xlsx C ABI.

use cpsl_core::{MountPermission, MountTable, Sandbox, XlsxGateway};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_double, c_int};
use std::sync::Arc;
use std::sync::Mutex;

#[repr(C)]
struct CellsXlsxWorkbook {
    _private: [u8; 0],
}

extern "C" {
    fn cells_xlsx_last_error() -> *const c_char;
    fn cells_xlsx_open(path: *const c_char) -> *mut CellsXlsxWorkbook;
    fn cells_xlsx_create() -> *mut CellsXlsxWorkbook;
    fn cells_xlsx_close(wb: *mut CellsXlsxWorkbook);
    fn cells_xlsx_sheet_count(wb: *const CellsXlsxWorkbook) -> c_int;
    fn cells_xlsx_sheet_name(
        wb: *const CellsXlsxWorkbook,
        sheet_index: c_int,
        buf: *mut c_char,
        buf_size: usize,
    ) -> c_int;
    fn cells_xlsx_get_type(
        wb: *const CellsXlsxWorkbook,
        sheet_index: c_int,
        col: c_int,
        row: c_int,
    ) -> c_int;
    fn cells_xlsx_get_number(
        wb: *const CellsXlsxWorkbook,
        sheet_index: c_int,
        col: c_int,
        row: c_int,
    ) -> c_double;
    fn cells_xlsx_get_bool(
        wb: *const CellsXlsxWorkbook,
        sheet_index: c_int,
        col: c_int,
        row: c_int,
    ) -> c_int;
    fn cells_xlsx_get_string(
        wb: *mut CellsXlsxWorkbook,
        sheet_index: c_int,
        col: c_int,
        row: c_int,
    ) -> *const c_char;
    fn cells_xlsx_set_number(
        wb: *mut CellsXlsxWorkbook,
        sheet_index: c_int,
        col: c_int,
        row: c_int,
        value: c_double,
    ) -> c_int;
    fn cells_xlsx_set_string(
        wb: *mut CellsXlsxWorkbook,
        sheet_index: c_int,
        col: c_int,
        row: c_int,
        value: *const c_char,
    ) -> c_int;
    fn cells_xlsx_set_bool(
        wb: *mut CellsXlsxWorkbook,
        sheet_index: c_int,
        col: c_int,
        row: c_int,
        value: c_int,
    ) -> c_int;
    fn cells_xlsx_write(wb: *const CellsXlsxWorkbook, path: *const c_char) -> c_int;
}

struct NativeCellsGateway {
    next_id: Mutex<u64>,
    books: Mutex<HashMap<String, *mut CellsXlsxWorkbook>>,
}

// cells_xlsx workbook handles are used from a single-threaded gateway lock in practice.
unsafe impl Send for NativeCellsGateway {}
unsafe impl Sync for NativeCellsGateway {}

impl NativeCellsGateway {
    fn new() -> Self {
        Self {
            next_id: Mutex::new(1),
            books: Mutex::new(HashMap::new()),
        }
    }

    fn last_error() -> String {
        unsafe {
            let p = cells_xlsx_last_error();
            if p.is_null() {
                return "unknown cells_xlsx error".into();
            }
            CStr::from_ptr(p).to_string_lossy().into_owned()
        }
    }

    fn store(&self, wb: *mut CellsXlsxWorkbook) -> String {
        let mut id = self.next_id.lock().unwrap();
        let key = format!("wb{id}");
        *id += 1;
        self.books.lock().unwrap().insert(key.clone(), wb);
        key
    }

    fn handle(&self, id: &str) -> Result<*mut CellsXlsxWorkbook, String> {
        self.books
            .lock()
            .unwrap()
            .get(id)
            .copied()
            .ok_or_else(|| "invalid workbook handle".into())
    }
}

impl Drop for NativeCellsGateway {
    fn drop(&mut self) {
        let books = std::mem::take(&mut *self.books.lock().unwrap());
        for (_, wb) in books {
            unsafe { cells_xlsx_close(wb) };
        }
    }
}

impl XlsxGateway for NativeCellsGateway {
    fn handle_json(&self, request_json: &str) -> Result<String, String> {
        let req: Value = serde_json::from_str(request_json).map_err(|e| e.to_string())?;
        let command = req
            .get("command")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "missing command".to_string())?;

        match command {
            "create" => {
                let wb = unsafe { cells_xlsx_create() };
                if wb.is_null() {
                    return Ok(json!({"ok":false,"error": Self::last_error()}).to_string());
                }
                let id = self.store(wb);
                Ok(json!({"ok":true,"workbook": id}).to_string())
            }
            "open" => {
                let path = req
                    .get("path")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| "open: missing path".to_string())?;
                let c_path = CString::new(path).map_err(|e| e.to_string())?;
                let wb = unsafe { cells_xlsx_open(c_path.as_ptr()) };
                if wb.is_null() {
                    return Ok(json!({"ok":false,"error": Self::last_error()}).to_string());
                }
                let id = self.store(wb);
                Ok(json!({"ok":true,"workbook": id}).to_string())
            }
            "close" => {
                let id = workbook_id(&req)?;
                if let Some(wb) = self.books.lock().unwrap().remove(&id) {
                    unsafe { cells_xlsx_close(wb) };
                }
                Ok(json!({"ok":true}).to_string())
            }
            "sheet_count" => {
                let wb = self.handle(&workbook_id(&req)?)?;
                let count = unsafe { cells_xlsx_sheet_count(wb) };
                if count < 0 {
                    return Ok(json!({"ok":false,"error": Self::last_error()}).to_string());
                }
                Ok(json!({"ok":true,"count": count}).to_string())
            }
            "get_string" => {
                let wb = self.handle(&workbook_id(&req)?)?;
                let sheet = int_field(&req, "sheet")? as c_int;
                let col = int_field(&req, "col")? as c_int;
                let row = int_field(&req, "row")? as c_int;
                let p = unsafe { cells_xlsx_get_string(wb, sheet, col, row) };
                if p.is_null() {
                    return Ok(json!({"ok":false,"error": Self::last_error()}).to_string());
                }
                let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
                Ok(json!({"ok":true,"value": s}).to_string())
            }
            "get_number" => {
                let wb = self.handle(&workbook_id(&req)?)?;
                let sheet = int_field(&req, "sheet")? as c_int;
                let col = int_field(&req, "col")? as c_int;
                let row = int_field(&req, "row")? as c_int;
                let n = unsafe { cells_xlsx_get_number(wb, sheet, col, row) };
                Ok(json!({"ok":true,"value": n}).to_string())
            }
            "set_string" => {
                let wb = self.handle(&workbook_id(&req)?)?;
                let sheet = int_field(&req, "sheet")? as c_int;
                let col = int_field(&req, "col")? as c_int;
                let row = int_field(&req, "row")? as c_int;
                let value = req
                    .get("value")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| "set_string: missing value".to_string())?;
                let c_value = CString::new(value).map_err(|e| e.to_string())?;
                let rc = unsafe { cells_xlsx_set_string(wb, sheet, col, row, c_value.as_ptr()) };
                if rc != 0 {
                    return Ok(json!({"ok":false,"error": Self::last_error()}).to_string());
                }
                Ok(json!({"ok":true}).to_string())
            }
            "set_number" => {
                let wb = self.handle(&workbook_id(&req)?)?;
                let sheet = int_field(&req, "sheet")? as c_int;
                let col = int_field(&req, "col")? as c_int;
                let row = int_field(&req, "row")? as c_int;
                let value = req
                    .get("value")
                    .and_then(|v| v.as_f64())
                    .ok_or_else(|| "set_number: missing value".to_string())?;
                let rc = unsafe { cells_xlsx_set_number(wb, sheet, col, row, value) };
                if rc != 0 {
                    return Ok(json!({"ok":false,"error": Self::last_error()}).to_string());
                }
                Ok(json!({"ok":true}).to_string())
            }
            "write" => {
                let wb = self.handle(&workbook_id(&req)?)?;
                let path = req
                    .get("path")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| "write: missing path".to_string())?;
                let c_path = CString::new(path).map_err(|e| e.to_string())?;
                let rc = unsafe { cells_xlsx_write(wb, c_path.as_ptr()) };
                if rc != 0 {
                    return Ok(json!({"ok":false,"error": Self::last_error()}).to_string());
                }
                Ok(json!({"ok":true}).to_string())
            }
            other => Err(format!("unsupported command {other}")),
        }
    }
}

fn workbook_id(req: &Value) -> Result<String, String> {
    req.get("workbook")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .ok_or_else(|| "missing workbook".to_string())
}

fn int_field(req: &Value, name: &str) -> Result<i64, String> {
    req.get(name)
        .and_then(|v| v.as_i64())
        .ok_or_else(|| format!("missing {name}"))
}

fn main() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let mut mounts = MountTable::new();
    mounts
        .add_mount(
            tmp.path().to_path_buf(),
            "/workdir",
            MountPermission::ReadWrite,
        )
        .unwrap();

    let gateway: Arc<dyn XlsxGateway> = Arc::new(NativeCellsGateway::new());
    let sandbox = Sandbox::builder()
        .mounts(mounts)
        .auto_tmp(false)
        .xlsx_gateway(gateway)
        .build()
        .expect("sandbox");

    let help = sandbox.exec("return xlsx.help()").expect("help");
    assert!(
        help.contains("open") && help.contains("write") && help.contains("create"),
        "help missing expected APIs: {help}"
    );
    println!("----- xlsx.help() -----");
    println!("{help}");
    println!("----- end help -----");
    println!("HELP_OK");

    let script = r#"
        local created = xlsx.create()
        local wb = created.workbook
        xlsx.set_string(wb, 0, 0, 0, "hello")
        xlsx.set_number(wb, 0, 1, 0, 42.5)
        xlsx.write(wb, "/workdir/out.xlsx")
        xlsx.close(wb)
        local reopened = xlsx.open("/workdir/out.xlsx")
        local wb2 = reopened.workbook
        local s = xlsx.get_string(wb2, 0, 0, 0).value
        local n = xlsx.get_number(wb2, 0, 1, 0).value
        xlsx.close(wb2)
        return s .. "|" .. tostring(n)
    "#;
    let result = sandbox.exec(script).expect("luau eval");
    println!("RESULT={result}");
    assert!(
        result.contains("hello") && result.contains("42.5"),
        "unexpected result: {result}"
    );

    let err = sandbox
        .exec(r#"return xlsx.open("/workdir/does_not_exist.xlsx")"#)
        .expect_err("invalid open should fail");
    println!("INVALID_OPEN={err}");
    println!("PASS luau create/set/write/reopen via real cells_xlsx");
}
