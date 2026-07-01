# Apple Agent Configuration

The Apple agent uses OpenAI-compatible Chat Completions endpoints only. Configure
it with a local `.env` file or process environment values:

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
- `app/apple/herm/Resources/.env`
- `app/apple/herm/Resources/.env.local`

`app/apple/herm/Resources/env.example` is a safe template and may be packaged.
Do not ship real API tokens in the app bundle. A bundled `.env` can be useful
for a local debug build, but it is not a safe production credential strategy.

The loader checks these locations, with later files overriding earlier values:

- The app bundle resource directory: `.env`, `env`, `.env.local`
- Application Support for the bundle identifier: `.env`, `.env.local`
- User Application Support: `.env`, `.env.local`
- From a repo-root working directory: `app/apple/herm/Resources/.env`,
  `app/apple/herm/Resources/.env.local`
- The current working directory: `.env`, `.env.local`
- Process environment values

For macOS development, `scripts/dev-apple-macos.sh` changes to the repo root
before launching the app, so a repo-root `.env` is available. For iOS simulator
or device builds, place the file in the app container's Application Support
directory or inject the values through the debug process environment.
