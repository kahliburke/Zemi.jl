// Where a paper's PDF is read at a page (see KBPdf.vue): from the service, or an arXiv paper's from
// arXiv. Browsers' viewers open a PDF at the page its address's `#page=` names.
export const pageFragment = (page?: number | null) => (page && page > 1 ? `#page=${page}` : '')
export const servicePdf = (api: string, id: string, page?: number | null) =>
  `${api}/api/pdf/${encodeURIComponent(id)}${pageFragment(page)}`
export const arxivPdf = (id: string, version = '', page?: number | null) =>
  `https://arxiv.org/pdf/${id}${version}${pageFragment(page)}`
