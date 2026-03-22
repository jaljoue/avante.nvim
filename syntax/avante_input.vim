" Syntax highlighting for Avante input buffers

if exists("b:current_syntax")
  finish
endif

" File references - @file:path/to/file
syntax match AvanteFileRef /@file:[^[:space:]]\+/ contains=AvanteFileRefMarker,AvanteFileRefPath
syntax match AvanteFileRefMarker /@file:/ contained
syntax match AvanteFileRefPath /\%(^\|@file:\)\@<=[^[:space:]]\+/ contained

" Directory references - @dir:path/to/dir  
syntax match AvanteDirectoryRef /@dir:[^[:space:]]\+/ contains=AvanteDirectoryRefMarker,AvanteDirectoryRefPath
syntax match AvanteDirectoryRefMarker /@dir:/ contained
syntax match AvanteDirectoryRefPath /\%(^\|@dir:\)\@<=[^[:space:]]\+/ contained

" Markdown file links - [name](file:///path)
syntax region AvanteMarkdownFileLink start=/\[.*\](file:\/\// end=/)\?/ contains=AvanteMarkdownLinkText,AvanteMarkdownLinkUrl
syntax match AvanteMarkdownLinkText /\[.*\]/ contained
syntax match AvanteMarkdownLinkUrl /(file:\/\/[^)]*)/ contained

" Mention patterns
syntax match AvanteMention /@codebase\>\?/
syntax match AvanteMention /@diagnostics\>\?/
syntax match AvanteMention /@file\>\?/
syntax match AvanteMention /@dir\>\?/

" Default highlight links
highlight default link AvanteFileRef Special
highlight default link AvanteFileRefMarker Keyword
highlight default link AvanteFileRefPath String
highlight default link AvanteDirectoryRef Special
highlight default link AvanteDirectoryRefMarker Keyword
highlight default link AvanteDirectoryRefPath String
highlight default link AvanteMarkdownFileLink Underlined
highlight default link AvanteMarkdownLinkText Normal
highlight default link AvanteMarkdownLinkUrl String
highlight default link AvanteMention Keyword

let b:current_syntax = "avante_input"
