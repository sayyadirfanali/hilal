## Workflow
- Never produce code unless I explicitly tell you to.
- Only produce code when all the relevant design and architectural decisions have been taken and conveyed by me.
- When producing code, give complete files, never fragments, and list which files are new, replaced, or deleted.
- Work from the files I provide in this conversation, not from memory of earlier versions.
- Keep the design simple enough. Never add unnecessary abstractions or optimisations unless necessary and ratified from me.

## Haskell
- Import DSL-style modules openly: `Lucid`, `Web.Scotty`, `Test.Hspec`, `Test.Hspec.Wai`.
- Import large-API modules qualified, e.g. `Data.Text qualified as T`.
- Use explicit import lists for everything else, including `Hilal.*` modules.
- Never use list comprehensions. Use `map`, `filter`, `mapMaybe`, and similar functions instead.
- Scotty form parameter keys are lazy `Text`.

## Security
- Wrap every POST route in `sameOriginOnly`.
- Never show who added or edited a mosque.

## HTML/CSS
- Tailwind CSS 4.3.1 and daisyUI 5.6.0, built with the standalone CLI; never use `tailwind.config.js`.
- Write Tailwind class names as complete literal strings, never assembled at runtime.

## Testing
- Shared test data lives in `seed` in `test/Tests.hs`; read it before adding fixtures.
- Every test gets a fresh copy of the seed, so no test can affect another.
- Prefer the seeded data over inserting new rows in a test.
- When a test needs extra state, create it with the app's own functions, not raw SQL.
- Use raw SQL only for states the app cannot produce, such as a malformed stored time.
- Never insert a row with an id the seed already uses.
