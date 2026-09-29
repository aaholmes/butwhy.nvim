File: ${butwhy.filename} (${context.filetype})

HIGHLIGHT (lines ${context.start_line}-${context.end_line}):
~~~${context.filetype}
${context.code}
~~~

SURROUNDING TEXT:
~~~${context.filetype}
${butwhy.surrounding}
~~~

The reader will now ask a question about the HIGHLIGHT. Answer that question.
