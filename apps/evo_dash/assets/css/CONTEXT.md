# Dashboard CSS

## Intent
`app.css` is the single Tailwind CSS 4 entry point for shared dashboard styling and page-specific adjustments.

## API Surface
The file contains DaisyUI light/dark themes, accent fill/standalone role tokens, shared component styles, Markdown, responsive input layout, and a final Genesis Assistant chat section.
The Assistant section scopes reading rhythm, quiet headings/quotes, code sizing and narrow-screen spacing to `#chat-messages .md-content`, and styles `.help-composer` plus `.help-caret` without changing layout or hook contracts.
Shared Markdown guards wrap long prose and constrain code/table width while preserving horizontal scrolling.

## Constraints
Use existing theme tokens and the standalone accent for focus outlines; keep fill/content roles unchanged.
Keep Assistant adjustments scoped, normal-flow message actions untouched, and reduced-motion overrides after the caret animation rule.
Do not edit generated static assets or translations.

## Validation
Run `mix tailwind evo_dash` from the repository root to compile the CSS and `git diff --check` for whitespace checks.
For browser review, check `/help` in light/dark themes at narrow and desktop widths, long URLs, code/tables, nested lists, RTL quotes, multiline composer, keyboard focus and reduced motion.
Build and source assertions do not substitute for browser visual validation.

## Routing Table
There are no child directories or separate CSS modules.
