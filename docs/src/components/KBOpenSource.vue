<!--
  Some of the open source projects the knowledge base relies on, ours first, each by its logo where
  it has one (see kbLogos.ts), else by a monogram.
-->
<script setup lang="ts">
import { MARKS } from './kbLogos'
import zemi from '../assets/zemi-icon.svg'
import kaimon from './logos/kaimon.jpg'
import kaimonSlate from './logos/kaimon-slate.svg'
import documenter from './logos/documenter.svg'
import documenterVitepress from './logos/documenter-vitepress.png'
import mupdf from './logos/mupdf.svg'
import mathjax from './logos/mathjax.svg'

// `image` is a logo file, `backed` when it is dark and needs a light ground on the dark theme; `mark`
// one of the brand marks in kbLogos.ts.
type Project = { name: string; url: string; what: string; image?: string; backed?: boolean; mark?: string }

const PROJECTS: Project[] = [
  { name: 'Zemi', url: 'https://github.com/kahliburke/Zemi.jl', what: 'The knowledge base, its site and its service', image: zemi },
  { name: 'Kaimon', url: 'https://github.com/kahliburke/Kaimon.jl', what: 'Runs the agents and serves their tools', image: kaimon },
  { name: 'Kaimon Slate', url: 'https://github.com/kahliburke/KaimonSlate.jl', what: 'The notebooks, and their pages on the site', image: kaimonSlate },
  { name: 'Julia', url: 'https://julialang.org', what: 'The language Zemi is written in', mark: 'julia' },
  { name: 'SQLite', url: 'https://sqlite.org', what: 'The database', mark: 'sqlite' },
  { name: 'Qdrant', url: 'https://qdrant.tech', what: 'Search by meaning', mark: 'qdrant' },
  { name: 'Ollama', url: 'https://ollama.com', what: 'The embedding models', mark: 'ollama' },
  { name: 'MuPDF', url: 'https://mupdf.com', what: 'Reading PDFs and cutting their figures', image: mupdf },
  { name: 'Git', url: 'https://git-scm.com', what: 'Codebases and their history', mark: 'git' },
  { name: 'HTTP.jl', url: 'https://github.com/JuliaWeb/HTTP.jl', what: 'The service and its requests' },
  { name: 'Caddy', url: 'https://caddyserver.com', what: 'HTTPS for the shared service', mark: 'caddy' },
  { name: 'Documenter.jl', url: 'https://github.com/JuliaDocs/Documenter.jl', what: 'Builds the site', image: documenter },
  { name: 'Documenter\u200bVitepress.jl', url: 'https://github.com/LuxDL/DocumenterVitepress.jl', what: 'Builds it with VitePress', image: documenterVitepress },
  { name: 'VitePress', url: 'https://vitepress.dev', what: 'The site', mark: 'vitepress' },
  { name: 'Vue', url: 'https://vuejs.org', what: 'The site\'s components', mark: 'vuedotjs' },
  { name: 'Node.js', url: 'https://nodejs.org', what: 'Builds and serves the site', mark: 'nodedotjs' },
  { name: 'markdown-it', url: 'https://github.com/markdown-it/markdown-it', what: 'Markdown', mark: 'markdown' },
  { name: 'MathJax', url: 'https://www.mathjax.org', what: 'Equations', image: mathjax, backed: true },
  { name: 'CodeMirror', url: 'https://codemirror.net', what: 'The editor', mark: 'codemirror' },
]

// A brand colour too dark to see on the dark theme's background, which there takes the text colour.
const dim = (hex: string | null) => {
  if (!hex) return false
  const [r, g, b] = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.2
}

// A project without a logo: its words' initials (`Two Words`, `TW`), or a word's capitals
// (`MathJax`, `MJ`), or its first two letters.
const monogram = (name: string) => {
  const words = name.replace(/\.jl$/, '').split(/\s+/)
  const caps = words.length > 1 ? words.map(w => w[0]) : words[0].match(/[A-Z]/g) ?? []
  return (caps.length >= 2 ? caps.slice(0, 2).join('') : name.slice(0, 2)).toUpperCase()
}
</script>

<template>
  <ul class="kbos">
    <li v-for="p in PROJECTS" :key="p.name">
      <a :href="p.url" target="_blank" rel="noopener">
        <img v-if="p.image" :src="p.image" alt="" :class="['kbos-logo', { backed: p.backed }]" />
        <svg v-else-if="p.mark" viewBox="0 0 24 24" :class="['kbos-logo', { dim: dim(MARKS[p.mark].color) }]" aria-hidden="true"
             :style="{ color: MARKS[p.mark].color ?? 'currentColor' }"><path :d="MARKS[p.mark].path" fill="currentColor" /></svg>
        <span v-else class="kbos-logo kbos-monogram" aria-hidden="true">{{ monogram(p.name) }}</span>
        <strong>{{ p.name }}</strong>
        <span class="kbos-what">{{ p.what }}</span>
      </a>
    </li>
  </ul>
</template>

<style scoped>
.kbos { list-style: none; padding: 0; margin: 1.5rem 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(10.5rem, 1fr)); gap: 0.8rem; }
.kbos li { margin: 0; }
.kbos a { display: flex; flex-direction: column; align-items: center; gap: 0.35rem; height: 100%; box-sizing: border-box; padding: 1rem 0.7rem;
  border: 1px solid var(--vp-c-divider); border-radius: 12px; text-align: center; text-decoration: none; color: var(--vp-c-text-1);
  transition: border-color 0.2s; }
.kbos a:hover { border-color: var(--vp-c-brand-1); }
.kbos-logo { width: 3rem; height: 3rem; object-fit: contain; margin-bottom: 0.3rem; }
img.kbos-logo { border-radius: 10px; }
.kbos-monogram { display: flex; align-items: center; justify-content: center; box-sizing: border-box; border-radius: 10px;
  background: var(--vp-c-default-soft); color: var(--vp-c-text-2); font-size: 1.05rem; font-weight: 700; letter-spacing: 0.02em; }
.kbos strong { font-size: 0.92rem; }
html.dark .kbos-logo.dim { color: var(--vp-c-text-1) !important; }
html.dark img.kbos-logo.backed { background: #f4f4f5; padding: 0.25rem; box-sizing: border-box; }
.kbos-what { font-size: 0.78rem; color: var(--vp-c-text-2); line-height: 1.35; }
</style>
