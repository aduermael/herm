# Apple Agent Configuration

The Apple agent uses OpenAI-compatible Chat Completions endpoints only. Configure
it with a local `.env` file:

```dotenv
OPENAI_BASE_URL=https://api.x.ai/v1
OPENAI_API_KEY=replace-with-token
OPENAI_MODEL=replace-with-model
```

`OPENAI_BASE_URL` must be an absolute HTTP or HTTPS base URL without embedded
credentials, query, or fragment. The client appends `/chat/completions`.

Local credential files are ignored by git and excluded from the Xcode target:

- `.env`
- `.env.local`
- `app/apple/herm/.env`
- `app/apple/herm/.env.local`
- `app/apple/herm/Resources/.env`
- `app/apple/herm/Resources/.env.local`

`app/apple/herm/Resources/env.example` is a safe template and may be packaged.
Do not ship real API tokens in the app bundle as resource files. The Xcode target
has a `Generate Env Constants` script phase that runs before Swift compilation in
Debug and Release. It reads local `.env` files and writes
`app/apple/herm/Generated/CPSLEnvConstants.swift`, which is also ignored by git.

The generator checks these locations, with later files overriding earlier values:

- Repo-root `.env`
- `app/apple/herm/.env`
- `app/apple/herm/Resources/.env`
- Repo-root `.env.local`
- `app/apple/herm/.env.local`
- `app/apple/herm/Resources/.env.local`

For macOS development, `scripts/dev-apple-macos.sh` changes to the repo root
before launching the app, but environment values are compiled at build time. If
you change `.env`, rebuild the app so the constants are regenerated. This keeps
credentials out of the public repo and out of copied bundle resources, but it is
not a production credential strategy because client-side constants can still be
extracted from the app binary. Move provider tokens server-side before shipping.
