# Zemi for Obsidian

A Zemi knowledge base beside your notes: a paper note's summary, topics and figures, the papers and
notes nearest the open note, citations to insert (`[@key]`), and notes for papers added by their arXiv
id or DOI. See the guide's "Projects, records and findings" page, under Obsidian, for what it does.

```sh
npm install
npm run build        # main.js; `npm run dev` rebuilds as you edit
```

Copy `main.js`, `manifest.json` and `styles.css` into `<vault>/.obsidian/plugins/zemi/`, turn it on
under Community plugins, and sign in from its settings. Desktop only: signing in listens on a port of
this machine for the browser to come back to.
