# User Guide for EvoGit 1.0

## Use Case: Generating slides for an AI Course

In this example, we will demonstrate how to use EvoGit 1.0 to generate a repository structure for an AI course.

The hierarchical structure is as follows:

```
ai-course/
├── README.md
├── Lecture 1/
│   ├── README.md
│   ├── 1_slide.html
│   └── 2_slide.html
├── Lecture 2/
│   ├── README.md
│   ├── 1_slide.html
│   └── 2_slide.html
└── Lecture 3/
...
```

There are three levels in this structure:
1. Course level (root), defining the overall course information, including:
    1. Metadata shared by this course (subject title, subject code, instructor, target audience, etc)
    2. Course description (what this course is about, key learning objectives, etc)
    3. Course syllabus (how many lectures, the topics of each lecture, etc)
2. Lecture level
    1. Metadata for that lecture (lecture number, title, etc)
    2. Lecture description (what this lecture is about, key points to cover, etc)
    3. Outline of slides to be created for that lecture (how many slides, topics of each slide, etc)
3. Slide level (files)
    1. Metadata for that slide (slide number, title, etc)
    2. Abstract of the slide (what this slide is about, what the animation would look like if any, etc)
    3. Content of the slide (the actual HTML content)

This structure can be perfectly mapped to EvoGit's hierarchical design, so we can write a simple markdown specification for the entire course as follows:

```markdown
# Structure

3 levels:
1. Course (root directory)
2. Lecture (subdirectory)
3. Slide (file)

# Specification for each level

## Course
- Metadata:
    - Subject Title: Introduction to Artificial Intelligence
    - Subject Code: AI101
    - Instructor: Prof. XYZ
    - Target Audience: Undergraduate students who finished basic programming courses but new to AI.
- Description:
    This course provides a comprehensive introduction to the field of Artificial Intelligence (AI).
    ... [more description here]
- Syllabus:
    - Lecture 1: Introduction to AI and History
    - Lecture 2: Search Algorithms
    ... [more lectures here]

## Lecture
- Outline
    Include 20 to 40 slides per lecture, depending on the topic, this constraint must be strictly followed.

## Slide
- Abstract:
    Choose from one of the three layouts: two-column animated slide, two-column code slide, three-column interactive quiz slide.
    By default, use the two-column animated slide layout, which can include text, images or short code snippets with animations on the right side.
    If the slide is only about code, consider using the two-column code slide layout.
    If the slide is about a review or key concept check, consider using the three-column interactive quiz slide layout.
- Content:
    Generate the HTML content for the slide based on the abstract.
    For each layout, follow the templates:
    ... [detailed HTML templates here]
```
This markdown specification can then be fed into the EvoGit system, which will generate the agents for each level and produce the final repository structure and content automatically.
