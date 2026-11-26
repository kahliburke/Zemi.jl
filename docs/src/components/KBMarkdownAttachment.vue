<script setup lang="ts">
import { ref, shallowRef } from 'vue'
import KBNeedsService from './KBNeedsService.vue'
import { isMarkdownMedia, mediaUrl, onLive } from './kbApi'
import { readAttachment } from './kbFrontmatter'
import { escapeText, loadMarkdown } from './kbMarkdown'

const previewBytes = 2 * 1024 * 1024
const tooLarge = 'This file is too large to preview (2 MiB limit).'
const file = shallowRef<ReturnType<typeof readAttachment> | null>(null)
const raw = ref('')
const error = ref('')
const render = shallowRef(escapeText)

onLive(() => {
  const controller = new AbortController()
  async function read() {
    const address = new URLSearchParams(location.search).get('file') ?? ''
    if (!isMarkdownMedia(address)) { error.value = 'Invalid Markdown attachment.'; return }
    try {
      const response = await fetch(mediaUrl(address), { signal: controller.signal })
      if (!response.ok || !/^text\/(plain|markdown)\b/i.test(response.headers.get('content-type') ?? ''))
        throw new Error('This attachment is unavailable.')
      raw.value = mediaUrl(address) + '?download=1'
      // Large attachments still download in full without sending the whole file through the renderer.
      if (Number(response.headers.get('content-length')) > previewBytes) {
        await response.body?.cancel()
        throw new Error(tooLarge)
      }
      const blob = await response.blob()
      if (blob.size > previewBytes) throw new Error(tooLarge)
      render.value = await loadMarkdown()
      file.value = readAttachment(await blob.text(), address.split('/').pop()!)
    } catch (e: any) { if (!controller.signal.aborted) error.value = e.message }
  }
  void read()
  return () => controller.abort()
})
</script>

<template>
  <KBNeedsService permission="tasks.view">
    <h1>{{ file?.title ?? 'Markdown attachment' }}</h1>
    <p v-if="file?.date">{{ file.date }}</p>
    <p v-if="raw"><a :href="raw" download>Download original Markdown</a></p>
    <p v-if="error" role="status">{{ error }}</p>
    <template v-else-if="file">
      <details v-if="file.metadata.length">
        <summary>Metadata</summary>
        <dl><template v-for="[key, value] in file.metadata" :key="key"><dt>{{ key }}</dt><dd>{{ value }}</dd></template></dl>
      </details>
      <pre data-share-text v-if="file.unparsed">{{ file.unparsed }}</pre>
      <div data-share-text class="kb-md" v-html="render(file.body)"></div>
    </template>
    <p v-else>Loading attachment…</p>
  </KBNeedsService>
</template>
