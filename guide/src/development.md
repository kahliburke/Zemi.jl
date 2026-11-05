# Development

## Tests

```sh
julia --project -e 'using Pkg; Pkg.test()'
```

Ollama, Qdrant and summarizers are stubbed. The Markdown renderer and editor tests need Node and
`npm install` in `docs/`; without them they are skipped.

Browser tests (Playwright, ports 8701 and 5181):

```sh
julia --project=app test/browser/run.jl [file.test.mjs …]
```

Run `npx playwright-core install chromium-headless-shell` in `docs/` once.

## Site development

`./zemi dev` serves the site through VitePress's dev server at `http://localhost:5173`
(`ZEMI_DEV_PORT` to change; components hot-reload) and the API under Revise. `./zemi dev --shared`
does the same for the shared service, with `ZEMI_LOCAL_SIGN_IN=1` to sign in without a provider.
`ZEMI_REVISE=0` leaves Revise out of `zemi --shared`.

## Demo and guide

`demo/` holds the demo knowledge base: `config.toml`, `content/`, and `seed.jl` (projects, tasks,
findings). Its papers come from a dataset made once by `demo/make_dataset.jl` (with Ollama, Qdrant
and Kaimon), kept in `~/.local/share/zemi/demo/dataset` rather than the cache, which is safe to
clear. The Docs workflow downloads it from the `demo-dataset-v1` release and checks it against
`demo/dataset.sha256`. To publish a new one:

```sh
tar --zstd -cf demo-dataset.tar.zst -C ~/.local/share/zemi/demo/dataset .
shasum -a 256 demo-dataset.tar.zst | cut -d' ' -f1 > demo/dataset.sha256
gh release upload demo-dataset-v1 demo-dataset.tar.zst --clobber
```

```sh
julia --project=app demo/serve.jl          # demo at http://localhost:8020
node demo/screenshots.mjs                  # guide screenshots: serves the demo, as the Docs workflow does
julia --project=app demo/build.jl          # guide + static demo, as deployed
```

Pushes to `main` deploy the guide and demo to GitHub Pages.
