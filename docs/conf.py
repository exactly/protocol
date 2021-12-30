# Configuration file for the Sphinx documentation builder.
#
# This file only contains a selection of the most common options. For a full
# list see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

# -- Path setup --------------------------------------------------------------

# If extensions (or modules to document with autodoc) are in another directory,
# add these directories to sys.path here. If the directory is relative to the
# documentation root, use os.path.abspath to make it absolute, like shown here.
#
import os
import sys
sys.path.insert(0, os.path.abspath('.'))


# -- Project information -----------------------------------------------------

project = 'Exactly Finance'
copyright = '2021, EXAFIN'
author = 'EXAFIN'

# The full version, including alpha/beta/rc tags
release = '1'


# -- General configuration ---------------------------------------------------

# Add any Sphinx extension module names here, as strings. They can be
# extensions coming with Sphinx (named 'sphinx.ext.*') or your custom
# ones.
extensions = [
    'matplotlib.sphinxext.plot_directive',
    'sphinxcontrib.plantuml',
    'sphinx.ext.autodoc',
    'sphinx.ext.imgmath',
    'sphinxcontrib.soliditydomain'
]
master_doc = 'index'

# Add any paths that contain templates here, relative to this directory.
templates_path = ['_templates']

# List of patterns, relative to source directory, that match files and
# directories to ignore when looking for source files.
# This pattern also affects html_static_path and html_extra_path.
exclude_patterns = ['_build', 'Thumbs.db', '.DS_Store']

# -- Options for HTML output -------------------------------------------------

latex_elements = {
    'papersize': 'a4paper',
    'pointsize': '12pt'
}

# -- Options for HTML output -------------------------------------------------

# The theme to use for HTML and HTML Help pages.  See the documentation for
# a list of builtin themes.
#
html_theme = 'bizstyle'
html_sidebars = {}
