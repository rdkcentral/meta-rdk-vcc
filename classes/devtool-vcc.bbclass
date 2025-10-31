"""
Copyright 2024 Sky, LLC
SPDX-License-Identifier: GPL-2.0-only

Some material is taken from the Yocto Project (devtool) and is:
Copyright (C) 2014+  Intel Corporation
Licensed under the GPLv2 License.
"""
# Module for development tool helpers to streamline source code checkout,
# patching, and potential packaging operations.  Customize actions
# within a build system for (Yocto/BitBake).

python () {
    command = d.getVar("command")
    if not command == None:
        if command == "checkout":
            post_funcs = d.getVarFlag("do_patch", 'postfuncs', False)
            new_list = post_funcs.replace("patch_task_postfunc", "")
            new_list = new_list.replace("devtool_post_patch", "")
            d.setVarFlag("do_patch", 'postfuncs', new_list)
            d.setVar("PATCHTOOL", "patch")

            # Replace the default devtool_post_unpack task from the devtool-source class
            # with the vcc_devtool_post_unpack function. The difference between these two functions 
            # is that the vcc_devtool_post_unpack is not calling the "setup_git_repo" with the
            # branch name in the DEVTOOL_DEVBRANCH variable.
            is_kernel_yocto = bb.data.inherits_class('kernel-yocto', d)
            if is_kernel_yocto:
                unpacktask = 'do_kernel_checkout'
            else:
                unpacktask = 'do_unpack'
            funcs_list = d.getVarFlag(unpacktask, 'postfuncs', False)
            funcs_list = funcs_list.replace("devtool_post_unpack", "vcc_devtool_post_unpack")
            d.setVarFlag(unpacktask, 'postfuncs', funcs_list)
}

python vcc_devtool_post_unpack() {
    import oe.recipeutils
    import shutil
    sys.path.insert(0, os.path.join(d.getVar('COREBASE'), 'scripts', 'lib'))
    import scriptutils
    from devtool import setup_git_repo

    tempdir = d.getVar('DEVTOOL_TEMPDIR')
    workdir = d.getVar('WORKDIR')
    srcsubdir = d.getVar('S')

    def _move_file(src, dst):
        """Move a file. Creates all the directory components of destination path."""
        dst_d = os.path.dirname(dst)
        if dst_d:
            bb.utils.mkdirhier(dst_d)
        shutil.move(src, dst)

    def _ls_tree(directory):
        """Recursive listing of files in a directory"""
        ret = []
        for root, dirs, files in os.walk(directory):
            ret.extend([os.path.relpath(os.path.join(root, fname), directory) for
                        fname in files])
        return ret

    is_kernel_yocto = bb.data.inherits_class('kernel-yocto', d)
    # Move local source files into separate subdir
    recipe_patches = [os.path.basename(patch) for patch in
                        oe.recipeutils.get_recipe_patches(d)]
    local_files = oe.recipeutils.get_recipe_local_files(d)

    if is_kernel_yocto:
        for key in [f for f in local_files if f.endswith('scc')]:
            with open(local_files[key], 'r') as sccfile:
                for l in sccfile:
                    line = l.split()
                    if line and line[0] in ('kconf', 'patch'):
                        cfg = os.path.join(os.path.dirname(local_files[key]), line[-1])
                        if cfg not in local_files.values():
                            local_files[line[-1]] = cfg
                            shutil.copy2(cfg, workdir)

    # Ignore local files with subdir={BP}
    srcabspath = os.path.abspath(srcsubdir)
    local_files = [fname for fname in local_files if
                    os.path.exists(os.path.join(workdir, fname)) and
                    (srcabspath == workdir or not
                    os.path.join(workdir, fname).startswith(srcabspath +
                        os.sep))]
    if local_files:
        for fname in local_files:
            _move_file(os.path.join(workdir, fname),
                        os.path.join(tempdir, 'oe-local-files', fname))
        with open(os.path.join(tempdir, 'oe-local-files', '.gitignore'),
                    'w') as f:
            f.write('# Ignore local files, by default. Remove this file '
                    'if you want to commit the directory to Git\n*\n')

    if srcsubdir == workdir:
        # Find non-patch non-local sources that were "unpacked" to srctree
        # directory
        src_files = [fname for fname in _ls_tree(workdir) if
                        os.path.basename(fname) not in recipe_patches]
        srcsubdir = d.getVar('DEVTOOL_PATCH_SRCDIR')
        # Move source files to S
        for path in src_files:
            _move_file(os.path.join(workdir, path),
                        os.path.join(srcsubdir, path))
    elif os.path.dirname(srcsubdir) != workdir:
        # Handle if S is set to a subdirectory of the source
        srcsubdir = os.path.join(workdir, os.path.relpath(srcsubdir, workdir).split(os.sep)[0])

    scriptutils.git_convert_standalone_clone(srcsubdir)

    # Make sure that srcsubdir exists
    bb.utils.mkdirhier(srcsubdir)
    if not os.listdir(srcsubdir):
        bb.warn("No source unpacked to S - either the %s recipe "
                "doesn't use any source or the correct source "
                "directory could not be determined" % d.getVar('PN'))

    # run the git command only for git repositories
    git_dir = os.path.join(srcsubdir, '.git')
    if os.path.isdir(git_dir):
        (stdout, _) = bb.process.run('git rev-parse HEAD', cwd=srcsubdir)
        initial_rev = stdout.rstrip()
        with open(os.path.join(tempdir, 'initial_rev'), 'w') as f:
            f.write(initial_rev)

    with open(os.path.join(tempdir, 'srcsubdir'), 'w') as f:
        f.write(srcsubdir)
}