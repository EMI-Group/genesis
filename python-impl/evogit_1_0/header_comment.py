"""A template for a header comment in different languages."""

import warnings
import os


# programming languages

# Python wants 2 empty lines after module docstring
python = """\"\"\"
{abstract}
\"\"\"


"""

c = """/*
{abstract}
*/"""

cpp = c

js = """/**
{abstract}
*/"""

java = """/**
{abstract}
*/"""

# markup languages
html = """<!--
{abstract}
-->"""

css = """/*
{abstract}
*/"""

md = """<!--
{abstract}
-->"""

templates = {
    "python": python,
    "c": c,
    "cpp": cpp,
    "js": js,
    "java": java,
    "html": html,
    "css": css,
    "md": md,
}

extensions = {
    ".py": "python",
    ".c": "c",
    ".cpp": "cpp",
    ".js": "js",
    ".java": "java",
    ".html": "html",
    ".css": "css",
    ".md": "md",
}


def format_header_comment(abstract, filename):
    """Format the header comment based on the file extension."""
    ext = os.path.splitext(filename)[1]
    lang = extensions.get(ext)
    if not lang:
        warnings.warn(f"Unknown file extension '{ext}'. Using default comment format.")
        return f"# {abstract}"  # default to a simple comment
    template = templates[lang]
    return template.format(abstract=abstract)
