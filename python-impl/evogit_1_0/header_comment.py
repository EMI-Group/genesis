"""A template for a header comment in different languages."""

import warnings
import os
import re


class HeaderCommentStyle:
    def __init__(self, template, regex_pattern):
        self.template = template
        self.regex = re.compile(regex_pattern, re.DOTALL)

    def format(self, abstract):
        return self.template.format(abstract=abstract)

    def extract(self, content):
        match = self.regex.search(content)
        if match:
            return match.group(1).strip()
        return None


# Regex patterns
# Matches """ ... """ at the start of the file
PYTHON_REGEX = r'^\s*"""(.*?)"""'
# Matches /* ... */ or /** ... */ at the start of the file
C_FAMILY_REGEX = r"^\s*/\*+(.*?)\*/"
# Matches <!-- ... --> at the start of the file
HTML_REGEX = r"^\s*<!--(.*?)-->"

# Define styles
python_style = HeaderCommentStyle(
    template='"""\n{abstract}\n"""\n\n\n', regex_pattern=PYTHON_REGEX
)

c_style = HeaderCommentStyle(
    template="/*\n{abstract}\n*/", regex_pattern=C_FAMILY_REGEX
)

javadoc_style = HeaderCommentStyle(
    template="/**\n{abstract}\n*/", regex_pattern=C_FAMILY_REGEX
)

html_style = HeaderCommentStyle(
    template="<!--\n{abstract}\n-->", regex_pattern=HTML_REGEX
)

# Map extensions to styles
EXTENSION_MAP = {
    ".py": python_style,
    ".c": c_style,
    ".cpp": c_style,
    ".js": javadoc_style,
    ".java": javadoc_style,
    ".css": c_style,
    ".html": html_style,
    ".md": html_style,
}


def format_header_comment(abstract, ext):
    """Format the header comment based on the file extension."""
    style = EXTENSION_MAP.get(ext)

    if not style:
        warnings.warn(f"Unknown file extension '{ext}'. Using default comment format.")
        return f"# {abstract}"  # default to a simple comment

    return style.format(abstract)


def extract_header_comment(content, filename):
    """Extract the header comment from file content based on extension."""
    ext = os.path.splitext(filename)[1]
    style = EXTENSION_MAP.get(ext)

    if not style:
        return None

    return
