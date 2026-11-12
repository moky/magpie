# -*- coding: utf-8 -*-
#
#   Copyright (c) 2026, Albert Moky. All rights reserved.
#   Use of this source code is governed by a MIT-style license
#   that can be found in the LICENSE file.
#
from setuptools import setup, find_packages

__version__ = '0.3.2'
__author__ = 'Albert Moky'
__contact__ = 'albert.moky@gmail.com'

with open('README.md', 'r', encoding='utf-8') as f:
    readme = f.read()

setup(
    name='magpie-bridge',
    version=__version__,
    url='https://github.com/moky/magpie',
    project_urls={
        'Bug Tracker': 'https://github.com/moky/magpie/issues',
        'Source Code': 'https://github.com/moky/magpie',
    },
    license='MIT',
    author=__author__,
    author_email=__contact__,
    description='Magpie Bridge SDK and UDP relay server',
    long_description=readme,
    long_description_content_type='text/markdown',
    packages=find_packages(exclude=['tests', 'tests.*']),
    python_requires='>=3.6',
    keywords='udp relay messaging bridge networking',
    classifiers=[
        'Programming Language :: Python :: 3',
        'License :: OSI Approved :: MIT License',
        'Operating System :: OS Independent',
    ],
    entry_points={
        'console_scripts': [
            'magpie-bridge=magpie_bridge.bridge.run:main',
        ],
    },
    extras_require={
        'enigma': ['cryptography>=2.0'],
    },
)
