# Zemi for Obsidian

A Zemi knowledge base beside your notes: a paper note's summary, topics and figures, the papers and
notes nearest the open note, citations to insert (`[@key]`) and linked to what they cite, `zemi` blocks
showing searches, references, tasks and findings, and notes for papers added by their arXiv id or DOI. See the guide's "Projects, records and findings" page, under Obsidian, for what it does.

```sh
zemi obsidian VAULT      # build it, install it in VAULT turned on, and connect the vault
```

Then reload Obsidian and sign in from the plugin's settings. Desktop only: signing in listens on a
port of this machine for the browser to come back to.

For working on it here: `npm install`, then `npm run dev` rebuilds `main.js` as you edit, and
`npm test` checks that it reads citations as Zemi does.
