"""
Copyright 2024 Sky, LLC
SPDX-License-Identifier: GPL-2.0-only

Some material is taken from the Yocto Project (devtool) and is:
Copyright (C) 2014+  Intel Corporation
Licensed under the GPLv2 License

This module provides functionality for 'checkout' command within a
development tool context. The "checkout" command sets up the build
environment to modify the source for an existing recipe.

It includes a variety of options for handling the checkout, including
specifying the source tree, enabling or disabling source extraction,
and configuring the build directory. It also adds options for
debugging, such as preserving the temporary directory.

devtool checkout:
* Parses a recipe, downloads and patches its sourcecode and set it to external source mode

devtool checkout_metalayer
* Does checkout for all the recipes belonging to a specified meta layer

Command-line Switches:

devtool checkout:
* **recipename:**  Required. The name of the recipe to checkout the code (without version, path, or extension).

devtool checkout_metalayer:
* **metalayer:**  Required. The name of the meta layer whose recipes to checkout (without version, path, or extension).

Common switches:

* **--srctree:**  Optional. Path to external source tree. If not specified, a default subdirectory will be used.
* **--extract, -x:**  Default. Extract source for recipe.
* **--no-extract, -n:**  Optional. Do not xtract source for recipe.
* **--same-dir, -s:**  Optional. Build in same directory as source.
* **--no-same-dir:**  Optional. Force build in a separate build directory.
* **--branch, -b:**  Optional. Name for development branch to checkout.
* **--no-overrides, -O:**  Optional. Do not create branches for other override configurations
* **--keep-temp:**  Optional. Keep temporary directory (for debugging)

Usage Example:
devtool checkout 'recipe-name'
devtool checkout_metalayer 'meta-layer-name'
"""

import os
import sys
import re
import shutil
import subprocess
import tempfile
import logging
import argparse
import argparse_oe
import scriptutils
import errno
import glob
import filecmp
from collections import OrderedDict
from devtool import exec_build_env_command, setup_tinfoil, check_workspace_recipe, use_external_build, setup_git_repo, recipe_to_append, get_bbclassextend_targets, update_unlockedsigs, check_prerelease_version, check_git_repo_dirty, check_git_repo_op, DevtoolError
from devtool import parse_recipe

logger = logging.getLogger('devtool')

override_branch_prefix = 'devtool-override-'

def _check_compatible_recipe(pn, d):
    """Check if the recipe is supported by devtool"""
    if pn == 'perf':
        raise DevtoolError("The perf recipe does not actually check out "
                           "source and thus cannot be supported by this tool",
                           4)

    if pn in ['kernel-devsrc', 'package-index'] or pn.startswith('gcc-source'):
        raise DevtoolError("The %s recipe is not supported by this tool" % pn, 4)

    if bb.data.inherits_class('image', d):
        raise DevtoolError("The %s recipe is an image, and therefore is not "
                           "supported by this tool" % pn, 4)

    if bb.data.inherits_class('populate_sdk', d):
        raise DevtoolError("The %s recipe is an SDK, and therefore is not "
                           "supported by this tool" % pn, 4)

    if bb.data.inherits_class('packagegroup', d):
        raise DevtoolError("The %s recipe is a packagegroup, and therefore is "
                           "not supported by this tool" % pn, 4)
    if d.getVar('DISTRO_CODENAME') == 'dunfell':
        if bb.data.inherits_class('meta', d):
            raise DevtoolError("The %s recipe is a meta-recipe, and therefore is "
                            "not supported by this tool" % pn, 4)
    if bb.data.inherits_class('externalsrc', d) and d.getVar('EXTERNALSRC'):
        # Not an incompatibility error per se, so we don't pass the error code
        raise DevtoolError("externalsrc is currently enabled for the %s "
                           "recipe. This prevents the normal do_patch task "
                           "from working. You will need to disable this "
                           "first." % pn)

def _vcc_extract_source(srctree, keep_temp, devbranch, sync, config, basepath, workspace, fixed_setup, d, tinfoil, no_overrides=False):
    """Extract sources of a recipe"""
    import oe.recipeutils
    import oe.patch
    import oe.path

    pn = d.getVar('PN')

    _check_compatible_recipe(pn, d)

    if sync:
        if not os.path.exists(srctree):
                raise DevtoolError("output path %s does not exist" % srctree)
    else:
        if os.path.exists(srctree):
            if not os.path.isdir(srctree):
                raise DevtoolError("output path %s exists and is not a directory" %
                                   srctree)
            elif os.listdir(srctree):
                raise DevtoolError("output path %s already exists and is "
                                   "non-empty" % srctree)

        if 'noexec' in (d.getVarFlags('do_unpack', False) or []):
            raise DevtoolError("The %s recipe has do_unpack disabled, unable to "
                               "extract source" % pn, 4)

    if not sync:
        # Prepare for shutil.move later on
        bb.utils.mkdirhier(srctree)
        os.rmdir(srctree)

    extra_overrides = []
    if not no_overrides:
        history = d.varhistory.variable('SRC_URI')
        for event in history:
            if not 'flag' in event:
                if d.getVar('DISTRO_CODENAME') == 'dunfell':
                    if event['op'].startswith(('_append[', '_prepend[')):
                        extra_overrides.append(event['op'].split('[')[1].split(']')[0])
                else:
                    if event['op'].startswith((':append[', ':prepend[')):
                        override = event['op'].split('[')[1].split(']')[0]
                        if not override.startswith('pn-'):
                            extra_overrides.append(override)
        # We want to remove duplicate overrides. If a recipe had multiple
        # SRC_URI_override += values it would cause mulitple instances of
        # overrides. This doesn't play nicely with things like creating a
        # branch for every instance of DEVTOOL_EXTRA_OVERRIDES.
        extra_overrides = list(set(extra_overrides))
        if extra_overrides:
            logger.info('SRC_URI contains some conditional appends/prepends - will create branches to represent these')

    initial_rev = None

    recipefile = d.getVar('FILE')
    appendfile = recipe_to_append(recipefile, config)
    is_kernel_yocto = bb.data.inherits_class('kernel-yocto', d)

    # We need to redirect WORKDIR, STAMPS_DIR etc. under a temporary
    # directory so that:
    # (a) we pick up all files that get unpacked to the WORKDIR, and
    # (b) we don't disturb the existing build
    # However, with recipe-specific sysroots the sysroots for the recipe
    # will be prepared under WORKDIR, and if we used the system temporary
    # directory (i.e. usually /tmp) as used by mkdtemp by default, then
    # our attempts to hardlink files into the recipe-specific sysroots
    # will fail on systems where /tmp is a different filesystem, and it
    # would have to fall back to copying the files which is a waste of
    # time. Put the temp directory under the WORKDIR to prevent that from
    # being a problem.
    tempbasedir = d.getVar('WORKDIR')
    bb.utils.mkdirhier(tempbasedir)
    tempdir = tempfile.mkdtemp(prefix='devtooltmp-', dir=tempbasedir)
    try:
        tinfoil.logger.setLevel(logging.WARNING)

        # FIXME this results in a cache reload under control of tinfoil, which is fine
        # except we don't get the knotty progress bar

        if os.path.exists(appendfile):
            appendbackup = os.path.join(tempdir, os.path.basename(appendfile) + '.bak')
            shutil.copyfile(appendfile, appendbackup)
        else:
            appendbackup = None
            bb.utils.mkdirhier(os.path.dirname(appendfile))
        logger.debug('writing append file %s' % appendfile)
        with open(appendfile, 'a') as f:
            f.write('###--- _vcc_extract_source\n')
            f.write('DEVTOOL_TEMPDIR = "%s"\n' % tempdir)
            f.write('DEVTOOL_DEVBRANCH = "%s"\n' % devbranch)
            if not is_kernel_yocto:
                f.write('PATCHTOOL = "patch"\n')
                f.write('PATCH_COMMIT_FUNCTIONS = "1"\n')
            if extra_overrides:
                f.write('DEVTOOL_EXTRA_OVERRIDES = "%s"\n' % ':'.join(extra_overrides))

            cmd = d.getVar("command", True)
            if not cmd == None:
                f.write('command = "%s"\n' % cmd)
            f.write('inherit devtool-source\n')
            f.write('inherit devtool-vcc\n')
            f.write('###--- _vcc_extract_source\n')

        update_unlockedsigs(basepath, workspace, fixed_setup, [pn])

        sstate_manifests = d.getVar('SSTATE_MANIFESTS')
        bb.utils.mkdirhier(sstate_manifests)
        preservestampfile = os.path.join(sstate_manifests, 'preserve-stamps')
        with open(preservestampfile, 'w') as f:
            f.write(d.getVar('STAMP'))
        try:
            if is_kernel_yocto:
                # We need to generate the kernel config
                task = 'do_configure'
            else:
                task = 'do_patch'

                if 'noexec' in (d.getVarFlags(task, False) or []) or 'task' not in (d.getVarFlags(task, False) or []):
                    logger.info('The %s recipe has %s disabled. Running only '
                                       'do_configure task dependencies' % (pn, task))

                    if 'depends' in d.getVarFlags('do_configure', False):
                        pn = d.getVarFlags('do_configure', False)['depends']
                        pn = pn.replace('${PV}', d.getVar('PV'))
                        pn = pn.replace('${COMPILERDEP}', d.getVar('COMPILERDEP'))
                        task = None

            # Run the fetch + unpack tasks
            res = tinfoil.build_targets(pn,
                                        task,
                                        handle_events=True)
        finally:
            if os.path.exists(preservestampfile):
                os.remove(preservestampfile)

        if not res:
            raise DevtoolError('Extracting source for %s failed' % pn)

        if not is_kernel_yocto and ('noexec' in (d.getVarFlags('do_patch', False) or []) or 'task' not in (d.getVarFlags('do_patch', False) or [])):
            workshareddir = d.getVar('S')
            if os.path.islink(srctree):
                os.unlink(srctree)

            os.symlink(workshareddir, srctree)

            # The initial_rev file is created in devtool_post_unpack function that will not be executed if
            # do_unpack/do_patch tasks are disabled so we have to directly say that source extraction was successful
            return True, True

        try:
            #with open(os.path.join(tempdir, 'initial_rev'), 'r') as f:
            #    initial_rev = f.read()

            with open(os.path.join(tempdir, 'srcsubdir'), 'r') as f:
                srcsubdir = f.read()
            git_dir = os.path.join(srcsubdir, ".git")
            if os.path.isdir(git_dir):
                with open(os.path.join(tempdir, 'initial_rev'), 'r') as f:
                    initial_rev = f.read()

        except FileNotFoundError as e:
            raise DevtoolError('Something went wrong with source extraction - the devtool-source class was not active or did not function correctly:\n%s' % str(e))
        srcsubdir_rel = os.path.relpath(srcsubdir, os.path.join(tempdir, 'workdir'))

        # Check if work-shared is empty, if yes
        # find source and copy to work-shared
        if is_kernel_yocto:
            workshareddir = d.getVar('STAGING_KERNEL_DIR')
            staging_kerVer = get_staging_kver(workshareddir)
            kernelVersion = d.getVar('LINUX_VERSION')

            # handle dangling symbolic link in work-shared:
            if os.path.islink(workshareddir):
                os.unlink(workshareddir)

            if os.path.exists(workshareddir) and (not os.listdir(workshareddir) or kernelVersion != staging_kerVer):
                shutil.rmtree(workshareddir)
                oe.path.copyhardlinktree(srcsubdir,workshareddir)
            elif not os.path.exists(workshareddir):
                oe.path.copyhardlinktree(srcsubdir,workshareddir)

        tempdir_localdir = os.path.join(tempdir, 'oe-local-files')
        srctree_localdir = os.path.join(srctree, 'oe-local-files')

        if sync:
            bb.process.run('git fetch file://' + srcsubdir + ' ' + devbranch + ':' + devbranch, cwd=srctree)

            # Move oe-local-files directory to srctree
            # As the oe-local-files is not part of the constructed git tree,
            # remove them directly during the synchrounizating might surprise
            # the users.  Instead, we move it to oe-local-files.bak and remind
            # user in the log message.
            if os.path.exists(srctree_localdir + '.bak'):
                shutil.rmtree(srctree_localdir, srctree_localdir + '.bak')

            if os.path.exists(srctree_localdir):
                logger.info('Backing up current local file directory %s' % srctree_localdir)
                shutil.move(srctree_localdir, srctree_localdir + '.bak')

            if os.path.exists(tempdir_localdir):
                logger.info('Syncing local source files to srctree...')
                shutil.copytree(tempdir_localdir, srctree_localdir)
        else:
            # Move oe-local-files directory to srctree
            if os.path.exists(tempdir_localdir):
                logger.info('Adding local source files to srctree...')
                shutil.move(tempdir_localdir, srcsubdir)

            shutil.move(srcsubdir, srctree)
            symlink_oelocal_files_srctree(d,srctree)

        if is_kernel_yocto:
            logger.info('Copying kernel config to srctree')
            shutil.copy2(os.path.join(tempdir, '.config'), srctree)

    finally:
        if appendbackup:
            shutil.copyfile(appendbackup, appendfile)
        elif os.path.exists(appendfile):
            os.remove(appendfile)
        if keep_temp:
            logger.info('Preserving temporary directory %s' % tempdir)
        else:
            shutil.rmtree(tempdir)
    return initial_rev, srcsubdir_rel

def get_default_srctree(config, recipename=''):
    """Get the default srctree path"""
    srctreeparent = config.get('General', 'default_source_parent_dir', config.workspace_path)
    if recipename:
        return os.path.join(srctreeparent, 'sources', recipename)
    else:
        return os.path.join(srctreeparent, 'sources')
def get_staging_kver(srcdir):
    # Kernel version from work-shared
    kerver = []
    staging_kerVer=""
    if os.path.exists(srcdir) and os.listdir(srcdir):
        with open(os.path.join(srcdir,"Makefile")) as f:
            version = [next(f) for x in range(5)][1:4]
            for word in version:
                kerver.append(word.split('= ')[1].split('\n')[0])
            staging_kerVer = ".".join(kerver)
    return staging_kerVer

def get_staging_kbranch(srcdir):
    staging_kbranch = ""
    if os.path.exists(srcdir) and os.listdir(srcdir):
        (branch, _) = bb.process.run('git branch | grep \* | cut -d \' \' -f2', cwd=srcdir)
        staging_kbranch = "".join(branch.split('\n')[0])
    return staging_kbranch

def symlink_oelocal_files_srctree(rd,srctree):
    import oe.patch
    if os.path.abspath(rd.getVar('S')) == os.path.abspath(rd.getVar('WORKDIR')):
        # If recipe extracts to ${WORKDIR}, symlink the files into the srctree
        # (otherwise the recipe won't build as expected)
        local_files_dir = os.path.join(srctree, 'oe-local-files')
        addfiles = []
        for root, _, files in os.walk(local_files_dir):
            relpth = os.path.relpath(root, local_files_dir)
            if relpth != '.':
                bb.utils.mkdirhier(os.path.join(srctree, relpth))
            for fn in files:
                if fn == '.gitignore':
                    continue
                destpth = os.path.join(srctree, relpth, fn)
                if os.path.exists(destpth):
                    os.unlink(destpth)
                if relpth != '.':
                    back_relpth = os.path.relpath(local_files_dir, root)
                    os.symlink('%s/oe-local-files/%s/%s' % (back_relpth, relpth, fn), destpth)
                else:
                    os.symlink('oe-local-files/%s' % fn, destpth)
                addfiles.append(os.path.join(relpth, fn))
        if addfiles:
            bb.process.run('git add %s' % ' '.join(addfiles), cwd=srctree)
            useroptions = []
            oe.patch.GitApplyTree.gitCommandUserOptions(useroptions, d=rd)
            bb.process.run('git %s commit -m "Committing local file symlinks\n\n%s"' % (' '.join(useroptions), oe.patch.GitApplyTree.ignore_commit_prefix), cwd=srctree)

def _add_md5(config, recipename, filename):
    """Record checksum of a file (or recursively for a directory) to the md5-file of the workspace"""
    import bb.utils

    def addfile(fn):
        md5 = bb.utils.md5_file(fn)
        with open(os.path.join(config.workspace_path, '.devtool_md5'), 'a+') as f:
            md5_str = '%s|%s|%s\n' % (recipename, os.path.relpath(fn, config.workspace_path), md5)
            f.seek(0, os.SEEK_SET)
            if not md5_str in f.read():
                f.write(md5_str)

    if os.path.isdir(filename):
        for root, _, files in os.walk(filename):
            for f in files:
                addfile(os.path.join(root, f))
    else:
        addfile(filename)

def checkout(args, config, basepath, workspace):
    """Entry point for the devtool 'checkout' subcommand"""
    import bb
    import oe.recipeutils
    import oe.patch
    import oe.path

    try:
        args.tinfoil = getattr(args, 'tinfoil', False)

        if args.tinfoil:
            tinfoil = args.tinfoil
        else:
            tinfoil = setup_tinfoil(basepath=basepath, tracking=True)
        checkout_recipe(args, config, basepath, workspace, tinfoil)
        if not args.tinfoil:
            logger.info("Shuting down tinfoil(checkout)..")
            tinfoil.shutdown()
        
    except Exception as e:
        bb.warn(f"Error in checkout for recipe {args.recipename}: {e}")
        if not args.tinfoil:
            logger.info("Shuting down the tinfoil")
            tinfoil.shutdown()

def find_bb_files(meta_layer_directory):
    import glob
    # Use glob to find all .bb files in the directory and its subdirectories
    bb_files = glob.glob(os.path.join(meta_layer_directory, '**', '*.bb'), recursive=True)
    return bb_files

def checkout_metalayer(args, config, basepath, workspace):
    """Entry point for the devtool 'checkout_metalayer' subcommand"""
    import bb
    import oe.recipeutils
    import oe.patch
    import oe.path
    try:
        args.tinfoil = getattr(args, 'tinfoil', False)

        if args.tinfoil:
            tinfoil = args.tinfoil
        else:
            tinfoil = setup_tinfoil(basepath=basepath, tracking=True)

        layer_paths = tinfoil.config_data.getVar('BBLAYERS').split()
        metalayer_to_process = ""
        for path in layer_paths:
            if os.path.split(path)[1] == args.metalayer:
                metalayer_to_process = path
                break
        if not metalayer_to_process:
            bb.warn('Could not find meta layer path for %s... aborting'%args.metalayer)
            if not args.tinfoil:
                logger.info('Shuting down the tinfoil')
                tinfoil.shutdown()
            return 0
        bb_list = find_bb_files(metalayer_to_process)
        for bbpath in bb_list:
            args.recipename = os.path.split(bbpath)[1].replace('.bb', '').split('_')[0]
            args.bbfile = bbpath
            # Since checkout_recipe function may change the value of args.no_extract for some recipes,
            # backup the value and restore it for the next invokation of the function for the next recipe.
            no_extract = args.no_extract
            checkout_recipe(args, config, basepath, workspace, tinfoil)
            args.no_extract = no_extract
        if not args.tinfoil:
            logger.info('Shuting down tinfoil..')
            tinfoil.shutdown()
    except Exception as e:
        bb.warn(f'Error in checkout for recipe {args.recipename}: {e}')
        if not args.tinfoil:
            logger.info('Shuting down the tinfoil')
            tinfoil.shutdown()


def checkout_recipe(args, config, basepath, workspace, tinfoil):

    # Set variable devtool_checkout_source_mode with the recipe name so that
    # the vcc framework will set the build mode of the recipe to true
    # in order to perform the build from the source.  
    tinfoil.config_data.setVar("devtool_checkout_source_mode", args.recipename)

    bb.warn("Processing Recipe:%s|"%args.recipename)
    rd = None
    try:
        rd = parse_recipe(config, tinfoil, args.recipename, True)
    except Exception as e:
        bb.warn(f"Parse recipe returned error for {args.recipename}: {e}")

    if not rd:
        bb.warn(f"Checkout is not done for {args.recipename}")
        return

    bbfile = rd.getVar('FILE')
    append_name = os.path.split(bbfile)[1].replace(".bb", ".bbappend")
    append_path = os.path.join(rd.getVar('TOPDIR'),"workspace/appends",append_name)

    if os.path.exists(append_path):
        logger.info('Skipping recipe: %s, it has already been checked out..'%args.recipename)
        return 
    # If the function is invoked from chekout_metalayer command,
    # check and verify that the recipe belongs to the meta layer
    # specified. If the recipe is not part of the specified meta layer,
    # then skip it from processing.
    args.bbfile = getattr(args, 'bbfile', False)
    if args.bbfile:
        if args.bbfile != rd.getVar('FILE'):
            logger.info('Skipping recipe: %s as it belongs to another meta layer..'%args.recipename)
            bb.warn(f"Checkout is not done for {args.recipename}")
            return
    
    # If the recipe is a package group, do the check out
    # for its component recipes.
    if bb.data.inherits_class('packagegroup', rd):
        rdeps_list = rd.getVar('RDEPENDS_%s'%rd.getVar('PN'))
        bb.warn("RDEPENDS: %s"%rdeps_list)
        for rdep in rdeps_list.split():
            args.recipename = rdep
            bb.warn('Processing component recipe:%s'%args.recipename)
            # Since checkout_recipe function may change the value of args.no_extract for some recipes,
            # backup the value and restore it for the next invokation of the function for the next recipe.
            no_extract = args.no_extract
            checkout_recipe(args, config, basepath, workspace, tinfoil)
            # Restore the value of args.no_extract
            args.no_extract = no_extract
        return

    rd.setVar("command", "checkout")
    if not rd:
        return 1

    pn = rd.getVar('PN')
    if pn != args.recipename:
        logger.info('Mapping %s to %s' % (args.recipename, pn))

    if args.srctree:
        srctree = os.path.abspath(args.srctree)
    else:
        srctree = get_default_srctree(config, pn)

    if args.no_extract and not os.path.isdir(srctree):
        if args.subparser_name == 'checkout':
            raise DevtoolError("--no-extract specified and source path %s does "
                        "not exist or is not a directory" %
                        srctree)

    recipefile = rd.getVar('FILE')
    appendfile = recipe_to_append(recipefile, config, args.wildcard)
    if os.path.exists(appendfile):
        if args.subparser_name == 'checkout':
            raise DevtoolError("Another variant of recipe %s is already in your "
                        "workspace (only one variant of a recipe can "
                        "currently be worked on at once)"
                        % pn)

    try:
        _check_compatible_recipe(pn, rd)
    except Exception as e:
        bb.warn(f"Could not process the recipe {args.recipename}: {e}")
        return
    
    initial_rev = None
    commits = []
    check_commits = False

    if bb.data.inherits_class('kernel-yocto', rd):
        # Current set kernel version
        kernelVersion = rd.getVar('LINUX_VERSION')
        srcdir = rd.getVar('STAGING_KERNEL_DIR')
        kbranch = rd.getVar('KBRANCH')

        staging_kerVer = get_staging_kver(srcdir)
        staging_kbranch = get_staging_kbranch(srcdir)
        if (os.path.exists(srcdir) and os.listdir(srcdir)) and (kernelVersion in staging_kerVer and staging_kbranch == kbranch):
            oe.path.copyhardlinktree(srcdir,srctree)
            workdir = rd.getVar('WORKDIR')
            srcsubdir = rd.getVar('S')
            localfilesdir = os.path.join(srctree,'oe-local-files')
            # Move local source files into separate subdir
            recipe_patches = [os.path.basename(patch) for patch in oe.recipeutils.get_recipe_patches(rd)]
            local_files = oe.recipeutils.get_recipe_local_files(rd)

            for key in local_files.copy():
                if key.endswith('scc'):
                    sccfile = open(local_files[key], 'r')
                    for l in sccfile:
                        line = l.split()
                        if line and line[0] in ('kconf', 'patch'):
                            cfg = os.path.join(os.path.dirname(local_files[key]), line[-1])
                            if not cfg in local_files.values():
                                local_files[line[-1]] = cfg
                                shutil.copy2(cfg, workdir)
                    sccfile.close()

            # Ignore local files with subdir={BP}
            srcabspath = os.path.abspath(srcsubdir)
            local_files = [fname for fname in local_files if os.path.exists(os.path.join(workdir, fname)) and  (srcabspath == workdir or not  os.path.join(workdir, fname).startswith(srcabspath + os.sep))]
            if local_files:
                for fname in local_files:
                    _move_file(os.path.join(workdir, fname), os.path.join(srctree, 'oe-local-files', fname))
                with open(os.path.join(srctree, 'oe-local-files', '.gitignore'), 'w') as f:
                    f.write('# Ignore local files, by default. Remove this file ''if you want to commit the directory to Git\n*\n')

            symlink_oelocal_files_srctree(rd,srctree)

            task = 'do_configure'
            res = tinfoil.build_targets(pn, task, handle_events=True)

            # Copy .config to workspace
            kconfpath = rd.getVar('B')
            logger.info('Copying kernel config to workspace')
            shutil.copy2(os.path.join(kconfpath, '.config'),srctree)

            # Set this to true, we still need to get initial_rev
            # by parsing the git repo
            args.no_extract = True

    if not args.no_extract:
        try:
            initial_rev, _ = _vcc_extract_source(srctree, args.keep_temp, args.branch, False, config, basepath, workspace, args.fixed_setup, rd, tinfoil, no_overrides=args.no_overrides)
        except Exception as e:
            bb.warn(f"Could not process the recipe {args.recipename}: {e}")
            return
        if os.path.isdir(os.path.join(srctree, ".git")):
            # This part is applicable to git repos only
            if not initial_rev:
                return 1
            logger.info('Source tree extracted to %s' % srctree)
            # Get list of commits since this revision
            (stdout, _) = bb.process.run('git rev-list --reverse %s..HEAD' % initial_rev, cwd=srctree)
            commits = stdout.split()

    # Need to grab this here in case the source is within a subdirectory
    srctreebase = srctree

    # Check that recipe isn't using a shared workdir
    s = os.path.abspath(rd.getVar('S'))
    workdir = os.path.abspath(rd.getVar('WORKDIR'))
    if s.startswith(workdir) and s != workdir and os.path.dirname(s) != workdir:
        # Handle if S is set to a subdirectory of the source
        srcsubdir = os.path.relpath(s, workdir).split(os.sep, 1)[1]
        srctree = os.path.join(srctree, srcsubdir)

    bb.utils.mkdirhier(os.path.dirname(appendfile))
    with open(appendfile, 'w') as f:
        f.write('FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"\n')
        # Local files can be modified/tracked in separate subdir under srctree
        # Mostly useful for packages with S != WORKDIR
        f.write('FILESPATH:prepend := "%s:"\n' %
                os.path.join(srctreebase, 'oe-local-files'))
        f.write('# srctreebase: %s\n' % srctreebase)

        f.write('\ninherit externalsrc\n')
        f.write('# NOTE: We use pn- overrides here to avoid affecting multiple variants in the case where the recipe uses BBCLASSEXTEND\n')
        if rd.getVar('DISTRO_CODENAME') == 'dunfell':
            f.write('EXTERNALSRC_pn-%s = "%s"\n' % (pn, srctree))
        else:
            f.write('EXTERNALSRC:pn-%s = "%s"\n' % (pn, srctree))

        b_is_s = use_external_build(args.same_dir, args.no_same_dir, rd)
        if b_is_s:
            if rd.getVar('DISTRO_CODENAME') == 'dunfell':
                f.write('EXTERNALSRC_BUILD_pn-%s = "%s"\n' % (pn, srctree))
            else:
                f.write('EXTERNALSRC_BUILD:pn-%s = "%s"\n' % (pn, srctree))

        if bb.data.inherits_class('kernel', rd):
            f.write('\ndo_patch[noexec] = "1"\n')
            if rd.getVar('DISTRO_CODENAME') == 'dunfell':
                f.write('SRCTREECOVEREDTASKS = "do_validate_branches do_kernel_checkout '
                        'do_fetch do_unpack do_kernel_configme do_kernel_configcheck"\n')
                f.write('\ndo_patch[noexec] = "1"\n')
                f.write('\ndo_configure_append() {\n'
                        '    cp ${B}/.config ${S}/.config.baseline\n'
                        '    ln -sfT ${B}/.config ${S}/.config.new\n'
                        '}\n')
            else:
                f.write('SRCTREECOVEREDTASKS = "do_validate_branches do_kernel_checkout '
                        'do_fetch do_unpack do_kernel_configcheck"\n')

                f.write('\ndo_configure:append() {\n'
                        '    cp ${B}/.config ${S}/.config.baseline\n'
                        '    ln -sfT ${B}/.config ${S}/.config.new\n'
                        '}\n')
                f.write('\ndo_kernel_configme:prepend() {\n'
                        '    if [ -e ${S}/.config ]; then\n'
                        '        mv ${S}/.config ${S}/.config.old\n'
                        '    fi\n'
                        '}\n')
        if bb.data.inherits_class('cmake', rd):
            f.write('EXTRA_OECMAKE += "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"\n') # enable generation of compile commands db
            f.write('do_compile_append () {\n') 
            f.write('\tif [ ! -f ${S}/compile_commands.json ]; then\n')
            f.write('\t\tmv -f ${B}/compile_commands.json ${S}\n')
            f.write('\t\tfi\n')
            f.write('}\n')
        else:
            topdir = tinfoil.config_data.getVar('TOPDIR')
            destpath = topdir + '/../openembedded-core/bitbake/bin/compiledb'
            if os.path.exists(destpath) is False:
                logger.info('Installing compiledb from pip3')
                if args.srctree:
                    srctree = os.path.abspath(args.srctree)
                else:
                    srctree = get_default_srctree(config, pn)
                bb.process.run('pip3 install compiledb', cwd=srctree)
                bb.process.run('ln -s /usr/local/bin/compiledb %s' % destpath, cwd=srctree)
            else:
                logger.info('compiledb already installed in ${TOPDIR}/../openembedded-core/bitbake/bin')
            f.write('do_compile_append () {\n') 
            f.write('\tcompiledb -S < ${S}/oe-logs/log.do_compile\n')
            f.write('\tif [ ! -f ${S}/compile_commands.json ]; then\n')
            f.write('\t\tmv -f ${B}/compile_commands.json ${S}\n')
            f.write('\tfi\n')
            f.write('}\n')
        if rd.getVarFlag('do_menuconfig','task'):
            if rd.getVar('DISTRO_CODENAME') == 'dunfell':
                f.write('\ndo_configure_append() {\n'
                '    if [ ! ${DEVTOOL_DISABLE_MENUCONFIG} ]; then\n'
                '        cp ${B}/.config ${S}/.config.baseline\n'
                '        ln -sfT ${B}/.config ${S}/.config.new\n'
                '    fi\n'
                '}\n')
            else:
                f.write('\ndo_configure:append() {\n'
                '    if [ ! ${DEVTOOL_DISABLE_MENUCONFIG} ]; then\n'
                '        cp ${B}/.config ${S}/.config.baseline\n'
                '        ln -sfT ${B}/.config ${S}/.config.new\n'
                '    fi\n'
                '}\n')
        
        f.write("\ndo_fetch[noexec] = \"1\"\n")
        f.write("do_unpack[noexec] = \"1\"\n")
        f.write("do_patch[noexec] = \"1\"\n")
        
        f.write('\ncopy_local_files() { \n'
                '   if [ -d \"${EXTERNALSRC:pn-${PN}}/oe-local-files\" ]; then\n'
                '      cp -rf ${EXTERNALSRC:pn-${PN}}/oe-local-files/* ${WORKDIR}/\n'
                '   fi\n'
                '}\n'
                'do_configure[prefuncs] += \" copy_local_files \"\n')
        if initial_rev:
            f.write('\n# initial_rev: %s\n' % initial_rev)
            for commit in commits:
                f.write('# commit: %s\n' % commit)

    update_unlockedsigs(basepath, workspace, args.fixed_setup, [pn])

    _add_md5(config, pn, appendfile)

    logger.info('Recipe %s now set up to build from %s' % (pn, srctree))
    return 0

def register_commands(subparsers, context):
    """Register devtool subcommands from this plugin"""
    defsrctree = get_default_srctree(context.config)
    parser_checkout = subparsers.add_parser('checkout', help='Checkout the source for an existing recipe',
                                       description='Sets up the build environment to modify the source for an existing recipe. The default behaviour is to extract the source being fetched by the recipe into a git tree so you can work on it; the patches will be applied but not commited',
                                       group='starting', order=90)
    parser_checkout.add_argument('recipename', help='Name of existing recipe to edit (just name - no version, path or extension)')
    parser_checkout.add_argument('srctree', nargs='?', help='Path to external source tree. If not specified, a subdirectory of %s will be used.' % defsrctree)
    parser_checkout.add_argument('--wildcard', '-w', action="store_true", help='Use wildcard for unversioned bbappend')
    group = parser_checkout.add_mutually_exclusive_group()
    group.add_argument('--extract', '-x', action="store_true", help='Extract source for recipe (default)')
    group.add_argument('--no-extract', '-n', action="store_true", help='Do not extract source, expect it to exist')
    group = parser_checkout.add_mutually_exclusive_group()
    group.add_argument('--same-dir', '-s', help='Build in same directory as source', action="store_true")
    group.add_argument('--no-same-dir', help='Force build in a separate build directory', action="store_true")
    parser_checkout.add_argument('--branch', '-b', help='Name for development branch to checkout (when not using -n/--no-extract) (default "%(default)s")')
    parser_checkout.add_argument('--no-overrides', '-O', action="store_true", help='Do not create branches for other override configurations')
    parser_checkout.add_argument('--keep-temp', help='Keep temporary directory (for debugging)', action="store_true")
    parser_checkout.set_defaults(func=checkout, fixed_setup=context.fixed_setup)
    
    parser_checkout_metalayer = subparsers.add_parser('checkout_metalayer', help='Checkout the source for all existing recipes in a meta layer',
                                       description='Sets up the build environment to modify the source for all existing recipes in a meta layer. The default behaviour is to extract the source being fetched by the recipe into a git tree so you can work on it; the patches will be applied but not commited',
                                       group='starting', order=90)
    parser_checkout_metalayer.add_argument('metalayer', help='Name of the meta layer to checkout recipes to edit from (just the name - not the entire path)')
    parser_checkout_metalayer.add_argument('srctree', nargs='?', help='Path to external source tree. If not specified, a subdirectory of %s will be used.' % defsrctree)
    parser_checkout_metalayer.add_argument('--wildcard', '-w', action="store_true", help='Use wildcard for unversioned bbappend')
    group = parser_checkout_metalayer.add_mutually_exclusive_group()
    group.add_argument('--extract', '-x', action="store_true", help='Extract source for recipe (default)')
    group.add_argument('--no-extract', '-n', action="store_true", help='Do not extract source, expect it to exist')
    group = parser_checkout_metalayer.add_mutually_exclusive_group()
    group.add_argument('--same-dir', '-s', help='Build in same directory as source', action="store_true")
    group.add_argument('--no-same-dir', help='Force build in a separate build directory', action="store_true")
    parser_checkout_metalayer.add_argument('--branch', '-b', help='Name for development branch to checkout (when not using -n/--no-extract) (default "%(default)s")')
    parser_checkout_metalayer.add_argument('--no-overrides', '-O', action="store_true", help='Do not create branches for other override configurations')
    parser_checkout_metalayer.add_argument('--keep-temp', help='Keep temporary directory (for debugging)', action="store_true")
    parser_checkout_metalayer.set_defaults(func=checkout_metalayer, fixed_setup=context.fixed_setup)
