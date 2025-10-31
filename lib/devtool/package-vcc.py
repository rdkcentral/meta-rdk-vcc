"""
Copyright 2024 Sky, LLC
SPDX-License-Identifier: GPL-2.0-only

Some material is taken from the Yocto Project (devtool) and is:
Copyright (C) 2014+  Intel Corporation
Licensed under the GPLv2 License
Devtool plugin for software packaging operations.

Provides the 'devtool package' command to:
* Verify the existence of a recipe within the workspace.
* Determine the packaging format (e.g., ipk, rpm, deb).
* Trigger the appropriate BitBake packaging task.
* Indicate the output location of generated packages

Command-line Switches:
* **recipename:**  Required. The name of the recipe to package.

Usage Example:
devtool package 'recipe-name'
"""

import os
import subprocess
import logging
from bb.process import ExecutionError
from devtool import exec_build_env_command, setup_tinfoil, check_workspace_recipe, DevtoolError

logger = logging.getLogger('devtool')

def package(args, config, basepath, workspace):
    """Entry point for the devtool 'package' subcommand"""
    check_workspace_recipe(workspace, args.recipename)

    tinfoil = setup_tinfoil(basepath=basepath, config_only=True)
    try:
        image_pkgtype = config.get('Package', 'image_pkgtype', '')
        if not image_pkgtype:
            image_pkgtype = tinfoil.config_data.getVar('IMAGE_PKGTYPE')

        deploy_dir_pkg = tinfoil.config_data.getVar('DEPLOY_DIR_%s' % image_pkgtype.upper())
    finally:
        tinfoil.shutdown()

    package_task = config.get('Package', 'package_task', 'package_write_%s' % image_pkgtype)
    try:
        exec_build_env_command(config.init_path, basepath, 'bitbake -c %s %s' % (package_task, args.recipename), watch=True)
    except bb.process.ExecutionError as e:
        # We've already seen the output since watch=True, so just ensure we return something to the user
        return e.exitcode

    logger.info('Your packages are in %s' % deploy_dir_pkg)

    return 0

def register_commands(subparsers, context):
    """Register devtool subcommands from the package plugin"""
    if not context.fixed_setup:
        parser_package = subparsers.add_parser('package',
                                               help='Build packages for a recipe',
                                               description='Builds packages for a recipe\'s output files',
                                               group='testbuild', order=-5)
        parser_package.add_argument('recipename', help='Recipe to package')
        parser_package.set_defaults(func=package)
