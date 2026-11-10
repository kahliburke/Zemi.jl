"""
A research group's knowledge base: papers and where they were discussed, parsed from PDF into
sections and passages, embedded in several layers (models × granularities) and searchable by keyword
and meaning, with summaries, findings, studies, a tutor, and projects whose tasks people and agents
work on. Runs as the `zemi` Kaimon extension and as a shared service.
"""
module Zemi

using Base64
using CodecZlib
using CodecZstd: ZstdCompressor, ZstdDecompressor, ZstdCompressorStream, ZstdDecompressorStream
using Dates
using LinearAlgebra: diagind, dot, norm, svd
import Random
using SHA
import Tar
using Sockets
using TOML
using UUIDs

using Colors: Colors, Color, Oklab, RGB, RGBA, TransparentColor, N0f8, red, green, blue, alpha
using DBInterface
using EzXML
using HTTP
using JSON
using PNGFiles
import libwebp_jll
using OpenSSL_jll: libcrypto
using SQLite
using Tables
import TimeZones
import KaimonGate

include("locked_dict.jl")
include("refusal.jl")
include("http.jl")
include("times.jl")
include("identifiers.jl")
include("kinds.jl")
include("qdrant.jl")

include("config.jl")
include("store.jl")
include("schema.jl")
include("accounts.jl")
include("tasks.jl")
include("questions.jl")
include("webpush.jl")
include("projects.jl")
include("milestones.jl")
include("auth.jl")
include("arxiv.jl")
include("pdf.jl")
include("chunking.jl")
include("embeddings.jl")
include("vectors.jl")
include("code.jl")
include("repos.jl")
include("openalex.jl")
include("ingest.jl")
include("dropped.jl")
include("search.jl")
include("summaries.jl")
include("kaimon_link.jl")
include("agents.jl")
include("evaluation.jl")
include("design.jl")
include("baseset.jl")
include("manage.jl")
include("sync.jl")
include("stores.jl")
include("s3.jl")
include("dataset.jl")
include("content_sync.jl")
include("access.jl")
include("capabilities.jl")
include("landscape.jl")
include("bibliography.jl")
include("authors.jl")
include("study.jl")
include("jobs.jl")
include("backup.jl")
include("records.jl")
include("resources.jl")
include("tools.jl")
include("task_tools.jl")
include("finding_tools.jl")
include("references.jl")
include("missing.jl")
include("watch.jl")
include("figures.jl")
include("daily.jl")
include("themes.jl")
include("page_images.jl")
include("notebooks.jl")
include("chat.jl")
include("processes.jl")
include("site_build.jl")
include("site_refresh.jl")
include("site_files.jl")
include("sign_in.jl")
include("service.jl")
include("local_key.jl")
include("site_packs.jl")
include("site_publish.jl")
include("dev.jl")
include("routes.jl")
include("admin.jl")
include("setup.jl")
include("model_choice.jl")
include("branding.jl")
include("escape.jl")
include("arxiv_categories.jl")
include("site.jl")
include("site_code.jl")
include("api.jl")
include("at_references.jl")
include("task_search.jl")
include("task_vectors.jl")
include("task_review.jl")
include("task_commits.jl")
include("media.jl")
include("project_access.jl")
include("document_access.jl")
include("site_records.jl")
include("agent_activity.jl")
include("people_activity.jl")
include("sources.jl")
include("upload_source.jl")
include("zotero.jl")
include("plugins.jl")
include("findings.jl")
include("finding_search.jl")
include("finding_comments.jl")
include("library.jl")
include("project_map.jl")
include("task_api.jl")
include("notify.jl")
include("mcp.jl")
include("confine.jl")
include("activity.jl")
include("oauth.jl")
include("terminal.jl")
include("cli.jl")
include("hosted.jl")
include("main.jl")

export Config, Layer, KB, load_config, open_kb, kb
export parse_arxiv_id, parse_pdf, chunk_paper
export add_papers!, add_pdf!, refresh_metadata!, fetch_pdf!, parse_paper!, embed_paper!, ingest!, remove_paper!, drop!, restore!
export drop_layer!, build_layer!, search, rankings, compare_rankings, similar_papers, PaperHit, Passage
export mentions, export_base_set, seed!
export Record, RecordSection, RecordFigure, RecordSegment, put_record!, delete_record!, purge_source!
export record_source!, PLUGIN_API, SourceRun
export add_codebase!, list_documents, reindex!, resummarize!, classify!, classification
export SyncTask, sync_plan, sync!, embed_records!
export FocusArea, landscape!, read_landscape
export Reference, split_references, paper_references, CitedWork, cited_works, find_on_arxiv!
export watch!, watched, start_watch, judge_watched!, pick_daily!, feature_daily!, start_daily, dailies
export make_notebook!, start_notebook, add_notebook!, paper_notebooks
export ask_chat!, chats, chat_messages
export Study, Theme, Synthesis, load_study, study_evidence, theme_overlaps, crossings, theme_timeline,
       find_candidates, add_candidates!, draft_theme!, draft_synthesis!, draft_study!, draft_markdown, search_arxiv,
       StudyMarkdown, study_text, papers_table, overlaps_table, crossings_table, write_study_bib
export cite_key, bib_entry, bibliography
export author_key, authors
export DatasetConfig, DirStore, S3Store, dataset_store, publish!, pull!, new_publish, follow_dataset!, issue_key, list_keys, revoke_key
export Summarizer, summarize_paper!, summaries, import_summaries!
export ProbeQuestion, probe_questions, evaluate_rankings, probe_rankings, score_ranking, fuse, judge_summaries
export DesignData, LayerCost, SummaryCost, measure_design_data, design_point
export create_tools, shutdown
export write_site, site_paper, related_papers
export project_map, read_project_map, remote_project_map, ProjectMap, Thread, threads, thread_state,
       glance_markdown, summary_markdown, activity_by_day, thread_tasks, finished, finished_markdown, done_at

end # module Zemi
