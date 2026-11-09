"""Shared selection and timing for sequential, isolated correctness groups."""
import json
import os
from pathlib import Path
import shutil
import tempfile
import time
from urllib.parse import urljoin


def select_groups(selection, groups):
    """Validate the complete ordered selection before any setup or case runs."""
    selected = tuple(groups) if selection == 'all' else tuple(selection.split(','))
    if (not selected or len(set(selected)) != len(selected)
            or any(name not in groups for name in selected)):
        raise ValueError(f'invalid case groups: {selection!r}; expected all or comma-separated {tuple(groups)}')
    return selected


def run_groups(suite, variable, groups, run, *, setup=None, preserve_all=False):
    """Run isolated groups, report progress to the shell guard and retain failures."""
    # Validate the entire selection before preparing anything or running cases.
    selection = os.environ.get(variable, 'all')
    selected = select_groups(selection, groups)
    if preserve_all and selection == 'all':
        selected = ('all',)
    temporary = Path(tempfile.mkdtemp(prefix=f'{suite}-'))
    try:
        if setup:
            setup(temporary)
        for name in selected:
            workspace = temporary / name
            workspace.mkdir()
            started = time.monotonic()
            print(f'{suite}: start group={name} workspace={workspace}', flush=True)
            progress = os.environ.get('VERIFY_GROUP_PROGRESS_FILE')
            if progress:
                progress_file = Path(progress)
                pending = progress_file.with_name(progress_file.name + '.tmp')
                pending.write_text(f'{int(time.time())} {name}\n')
                pending.replace(progress_file)
            try:
                run(name, workspace)
            except BaseException:
                print(f'{suite}: FAIL group={name} elapsed={time.monotonic() - started:.1f}s '
                      f'rerun: {variable}={name}', flush=True)
                raise
            finally:
                if progress:
                    pending.write_text('')
                    pending.replace(progress_file)
            print(f'{suite}: PASS group={name} elapsed={time.monotonic() - started:.1f}s', flush=True)
    except BaseException:
        print(f'{suite}: retained workspaces: {temporary}', flush=True)
        raise
    else:
        shutil.rmtree(temporary)


class PreparedFixture:
    """Reuse only pristine sources and Pub metadata within one harness process.

    Build scripts, workers and graphs contain workspace paths and are excluded.
    An optional warm callback may compile the stock package CLI, which imports
    dependency packages but never the fixture builder.
    """
    def __init__(self, template, *, warm=None):
        self.template = template
        self.warm = warm
        self.ready = False

    def copy(self, root, prepare):
        """Prepare once and copy sources and reusable CLI assets without build state."""
        if not self.ready:
            prepare(self.template)
            config = self.template / '.dart_tool/package_config.json'
            data = json.loads(config.read_text())
            base = config.as_uri()
            package_uri = self.template.as_uri() + '/'
            for package in data['packages']:
                absolute = urljoin(base, package['rootUri'])
                # Packages inside the fixture move with the copy. External
                # dependencies (including SDK/cache links) keep resolved paths.
                if absolute.rstrip('/') == package_uri.rstrip('/'):
                    package['rootUri'] = '../'
                elif absolute.startswith(package_uri):
                    package['rootUri'] = '../' + absolute[len(package_uri):]
                else:
                    package['rootUri'] = absolute
            config.write_text(json.dumps(data, indent=2) + '\n')
            if self.warm:
                self.warm(self.template)
            self.ready = True

        def ignore(directory, names):
            """Limit .dart_tool copies to Pub metadata and the stock package CLI."""
            if Path(directory) == self.template / '.dart_tool':
                return set(names) - {'package_config.json', 'package_graph.json', 'pub'}
            if Path(directory) == self.template / '.dart_tool/pub':
                return set(names) - {'bin'}
            if Path(directory) == self.template / '.dart_tool/pub/bin':
                return set(names) - {'build_runner'}
            return ()

        shutil.copytree(self.template, root, symlinks=True, ignore=ignore)
