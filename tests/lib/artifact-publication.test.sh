#!/usr/bin/env bash
# Publication transactions reject stale readers and recover interrupted replacements.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHONPATH="$ROOT/lib" python3 - "$ROOT" <<'PYTEST'
import json, os, subprocess, sys, tempfile
from pathlib import Path
root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as work:
    folder = Path(work) / 'fixture'
    folder.mkdir()
    state = {'slug':'fixture','currentPhase':'spec','artifacts':{'spec':'SPEC.md','plan':'PLAN.md'},'artifactPublication':{'version':1,'generation':0,'evidenceEpoch':0,'migration':None,'participantsVersion':1}}
    (folder/'feature.json').write_text(json.dumps(state))
    (folder/'SPEC.md').write_text('old spec')
    (folder/'PLAN.md').write_text('old plan')
    def run(op, *args, code=0, env=None, trusted=False):
        command = ['bash',str(root/'lib/artifact-publication.sh'),op,'--feature-dir',str(folder),*args]
        if trusted:
            command = [sys.executable, '-c', "import artifact_publication as a, sys; a.main(sys.argv[1:], allowed_updates={'currentPhase'})", op, '--feature-dir', str(folder), *args]
        if env and 'INJECT_POINT' in env:
            script = "import artifact_publication as a, os, sys\ndef fail(point):\n if point == os.environ['INJECT_POINT']: raise OSError('injected failure')\ntry: a.main(sys.argv[1:], failure=fail, allowed_updates={'currentPhase'})\nexcept OSError: sys.exit(2)"
            command = [sys.executable, '-c', script, op, '--feature-dir', str(folder), *args]
        result = subprocess.run(command,capture_output=True,text=True,env=env)
        assert result.returncode == code, (op,result.returncode,result.stderr)
        return json.loads(result.stdout) if result.stdout else None
    first = run('capture')
    second = run('capture')
    (folder/'token.json').write_text(json.dumps(first))
    staging = folder/'publication-staging'
    from artifact_publication import stage
    assert stage(folder, 'spec', b'new spec') == 'publication-staging/spec'
    (staging/'plan').write_text('new plan')
    manifest = {'version':1,'files':[{'source':'publication-staging/spec','target':'spec'},{'source':'publication-staging/plan','target':'plan'}],'updates':[{'path':'currentPhase','value':'plan'}]}
    (folder/'manifest.json').write_text(json.dumps(manifest))
    run('publish','--token',str(folder/'token.json'),'--manifest',str(folder/'manifest.json'),code=1)
    refreshed = run('publish','--token',str(folder/'token.json'),'--manifest',str(folder/'manifest.json'),trusted=True)
    assert refreshed['generation'] == 1
    assert json.loads((folder/'feature.json').read_text())['artifactPublication']['evidenceEpoch'] == 0
    original = [(folder/name).read_bytes() for name in ['SPEC.md','PLAN.md','feature.json']]
    (folder/'token.json').write_text(json.dumps(second))
    run('publish','--token',str(folder/'token.json'),'--manifest',str(folder/'manifest.json'),code=1)
    assert original == [(folder/name).read_bytes() for name in ['SPEC.md','PLAN.md','feature.json']]
    print('PASS: stale reader cannot replace artifacts, state, or phase acknowledgment')
    (folder/'token.json').write_text(json.dumps(refreshed))
    (folder/'own.json').write_text(json.dumps(dict(manifest, updates=[])))
    own = run('publish','--token',str(folder/'token.json'),'--manifest',str(folder/'own.json'))
    assert own['generation'] == 2
    print('PASS: only the producer own refreshed token authorizes its next publication')
    for point in ('staging', '1', '2', 'state'):
        token = run('capture')
        (folder/'token.json').write_text(json.dumps(token))
        (staging/'spec').write_text('interrupted spec ' + point)
        (staging/'plan').write_text('interrupted plan ' + point)
        before = [(folder/name).read_bytes() for name in ['SPEC.md','PLAN.md']]
        env = dict(os.environ, INJECT_POINT=point,
                   LOOP_SPEC_STORE=str(root/'lib/supervisor/store-mirror.sh'), LOOP_SPEC_STORE_DIR=str(Path(work)/'mirror'))
        run('publish','--token',str(folder/'token.json'),'--manifest',str(folder/'manifest.json'),code=2,env=env)
        assert (folder/'publication-generations/active.json').exists()
        import shutil
        shutil.rmtree(folder)
        subprocess.run(['bash',str(root/'lib/supervisor/store.sh'),'open',str(folder)],env=env,check=True,stdout=subprocess.DEVNULL)
        run('capture',code=1)
        if point == '1':
            saved = (folder/'PLAN.md').read_bytes()
            (folder/'PLAN.md').write_text('later user edit')
            partial = (folder/'SPEC.md').read_bytes()
            run('recover',code=1)
            assert (folder/'PLAN.md').read_text() == 'later user edit'
            assert (folder/'SPEC.md').read_bytes() == partial
            (folder/'PLAN.md').write_bytes(saved)
        recovered = run('recover')
        assert recovered['generation'] > token['generation']
        assert before == [(folder/name).read_bytes() for name in ['SPEC.md','PLAN.md']]
        assert json.loads((folder/'feature.json').read_text())['currentPhase'] == 'plan'
    print('PASS: each interrupted replacement recovers durable mirror originals')
    token = run('capture')
    (folder/'token.json').write_text(json.dumps(token))
    (folder/'SPEC.md').write_text('changed input')
    run('publish','--token',str(folder/'token.json'),'--manifest',str(folder/'manifest.json'),code=1)
    token = run('capture')
    (folder/'token.json').write_text(json.dumps(token))
    for field in ('version', 'generation'):
        malformed = dict(token)
        malformed[field] = True if field == 'version' else float(token[field])
        (folder/'token.json').write_text(json.dumps(malformed))
        run('publish','--token',str(folder/'token.json'),'--manifest',str(folder/'manifest.json'),code=1)
    (folder/'token.json').write_text(json.dumps(token))
    unchanged = (folder/'feature.json').read_bytes()
    for field in ('branch', 'baseSha', 'baseBranch', 'commands', 'autonomous', 'currentPhase'):
        (folder/'bad.json').write_text(json.dumps(dict(manifest, updates=[{'path':field,'value':'forged'}])))
        run('publish','--token',str(folder/'token.json'),'--manifest',str(folder/'bad.json'),code=1)
        assert (folder/'feature.json').read_bytes() == unchanged
    for source, target in [('../outside','spec'),('SPEC.md','spec'),('publication-staging/spec','feature.json')]:
        bad = dict(manifest, files=[{'source':source,'target':target}])
        (folder/'bad.json').write_text(json.dumps(bad))
        run('publish','--token',str(folder/'token.json'),'--manifest',str(folder/'bad.json'),code=1)
    (staging/'link').symlink_to(folder/'SPEC.md')
    (folder/'bad.json').write_text(json.dumps(dict(manifest,files=[{'source':'publication-staging/link','target':'spec'}])))
    run('publish','--token',str(folder/'token.json'),'--manifest',str(folder/'bad.json'),code=1)
    state = json.loads((folder/'feature.json').read_text())
    state['artifactPublication']['migration'] = {'id':'fixture','previewDigest':'a'*64,'phase':'applying','originalGeneration':0,'publishedHashes':{}}
    (folder/'feature.json').write_text(json.dumps(state))
    run('capture',code=1)
    result = subprocess.run(['bash',str(root/'lib/feature-write.sh'),'set',str(folder),'currentPhase','"execute"'],capture_output=True)
    assert result.returncode == 1
    print('PASS: changed inputs, unsafe paths, and active migration fail closed')
    for git_workspace in (False, True):
        project = Path(work) / ('git' if git_workspace else 'workspace')
        realistic = project / '.loop-spec/features/release.7'
        realistic.mkdir(parents=True)
        if git_workspace:
            subprocess.run(['git','init','-q',str(project)],check=True)
        initial = {'slug':'release.7','artifacts':{'spec':None,'plan':None,'tasks':str(realistic/'tasks.json'),'patternsSource':'caller metadata'},'artifactPublication':{'version':1,'generation':0,'evidenceEpoch':0,'migration':None,'participantsVersion':1}}
        (realistic/'feature.json').write_text(json.dumps(initial))
        (realistic/'tasks.json').write_text('[]')
        from artifact_publication import capture_locked, locked_feature, publish_locked
        with locked_feature(realistic):
            ingress = capture_locked(realistic)
            assert ingress['inputs']['tasks']['hash'] is not None
            assert 'patternsSource' not in ingress['inputs']
            assert ingress['inputs']['spec']['path'] == str(project/'docs/loop-spec/features/release.7/SPEC.md')
            source = stage(realistic, 'first-spec', b'first specification')
            refreshed = publish_locked(realistic, ingress, {'version':1,'files':[{'source':source,'target':'spec'}],'updates':[]})
            assert refreshed['generation'] == 1
        assert (project/'docs/loop-spec/features/release.7/SPEC.md').read_text() == 'first specification'
    print('PASS: first publication and absolute tasks pointers work in Git and non-Git workspaces')
    from artifact_publication import recover_locked
    origin = Path(work)/'original/.loop-spec/features/moved'
    origin.mkdir(parents=True)
    original_docs = Path(work)/'original/docs/loop-spec/features/moved'
    original_docs.mkdir(parents=True)
    (original_docs/'SPEC.md').write_text('original spec')
    (origin/'tasks.json').write_text('original tasks')
    initial = {'slug':'moved','artifacts':{'spec':'docs/loop-spec/features/moved/SPEC.md','tasks':str(origin/'tasks.json')},'artifactPublication':{'version':1,'generation':0,'evidenceEpoch':0,'migration':None,'participantsVersion':1}}
    (origin/'feature.json').write_text(json.dumps(initial))
    os.environ['LOOP_SPEC_STORE'] = str(root/'lib/supervisor/store-mirror.sh')
    os.environ['LOOP_SPEC_STORE_DIR'] = str(Path(work)/'relocation-mirror')
    with locked_feature(origin):
        ingress = capture_locked(origin)
        files = [{'source':stage(origin,key,content),'target':key} for key,content in [('spec',b'partial spec'),('tasks',b'partial tasks')]]
        def stop_after_tasks(point):
            if point == '2':
                raise OSError('simulated process death')
        try:
            publish_locked(origin, ingress, {'version':1,'files':files,'updates':[]}, failure=stop_after_tasks)
        except OSError:
            pass
        else:
            raise AssertionError('failure injection did not run')
    resumed = Path(work)/'resumed/.loop-spec/features/moved'
    resumed_docs = Path(work)/'resumed/docs/loop-spec/features/moved'
    resumed_docs.mkdir(parents=True)
    (resumed_docs/'SPEC.md').write_text('original spec')
    subprocess.run(['bash',str(root/'lib/supervisor/store.sh'),'open',str(resumed)],check=True,stdout=subprocess.DEVNULL)
    with locked_feature(resumed):
        recovered = recover_locked(resumed, registry={'tasks':'tasks.json'})
    assert (resumed/'tasks.json').read_text() == 'original tasks'
    assert (resumed_docs/'SPEC.md').read_text() == 'original spec'
    assert (origin/'tasks.json').read_text() == 'partial tasks'
    assert (original_docs/'SPEC.md').read_text() == 'partial spec'
    assert recovered['inputs']['tasks']['path'] == str(resumed/'tasks.json')
    print('PASS: relocated mirror recovery uses registered new roots and never writes the old checkout')
    from unittest import TestCase
    from unittest.mock import patch
    import artifact_publication as publication
    assertions = TestCase()
    os.environ.pop('LOOP_SPEC_STORE', None)
    for second_failure in ('persist', 'write_state_locked'):
        interrupted = Path(work)/('recovery-' + second_failure)
        interrupted.mkdir()
        initial = {'slug':'retry','artifacts':{'spec':'SPEC.md'},'artifactPublication':{'version':1,'generation':0,'evidenceEpoch':0,'migration':None,'participantsVersion':1}}
        (interrupted/'feature.json').write_text(json.dumps(initial))
        (interrupted/'SPEC.md').write_text('original')
        with locked_feature(interrupted):
            ingress = capture_locked(interrupted)
            source = stage(interrupted, 'spec', b'candidate')
            def stop_after_state(point):
                if point == 'state':
                    raise OSError('publication interrupted after state')
            with assertions.assertRaises(OSError):
                publish_locked(interrupted, ingress, {'version':1,'files':[{'source':source,'target':'spec'}],'updates':[]}, failure=stop_after_state)
            replace = os.replace
            def stop_completion(source, target):
                if Path(target).name == 'recovered.json':
                    raise OSError('recovery interrupted before completion marker')
                return replace(source, target)
            with patch.object(publication.os, 'replace', side_effect=stop_completion):
                with assertions.assertRaises(OSError):
                    recover_locked(interrupted)
            durable_state = (interrupted/'feature.json').read_bytes()
            with patch.object(publication, second_failure, side_effect=OSError('recovery interrupted before state write')):
                with assertions.assertRaises(OSError):
                    recover_locked(interrupted)
            edited = json.loads(durable_state)
            edited['warnings'] = ['later user edit']
            (interrupted/'feature.json').write_text(json.dumps(edited))
            with assertions.assertRaisesRegex(ValueError, 'recovery refuses changed target'):
                recover_locked(interrupted)
            (interrupted/'feature.json').write_bytes(durable_state)
            completed = recover_locked(interrupted)
        assert completed['generation'] == 2
        assert (interrupted/'SPEC.md').read_text() == 'original'
        assert (interrupted/'feature.json').read_bytes() == durable_state
        assert not (interrupted/'publication-generations/active.json').exists()
    print('PASS: repeated recovery interruptions reuse one generation and still refuse later user edits')
    for point in ('1', '2', '3', 'state'):
        participant = Path(work)/('sink-' + point)
        participant.mkdir()
        external = Path(work)/('private-' + point)
        external.mkdir()
        (participant/'feature.json').write_text(json.dumps(initial))
        (participant/'SPEC.md').write_text('approved document')
        (external/'index').write_bytes(b'original index')
        archive = external/'state/feature.json'
        registry = {'archive':str(archive), 'index':str(external/'index')}
        with locked_feature(participant):
            with assertions.assertRaisesRegex(ValueError, 'escapes'):
                capture_locked(participant, registry=registry)
            ingress = capture_locked(participant, registry=registry, external_roots=[external])
            files = [
                {'source':stage(participant, 'archive', b'approved document'), 'target':'archive'},
                {'source':None, 'target':'spec'},
                {'source':stage(participant, 'index', b'candidate index'), 'target':'index'},
            ]
            def stop_sink(location):
                if location == point:
                    raise OSError('sink interrupted at ' + point)
            with assertions.assertRaises(OSError):
                publish_locked(participant, ingress, {'version':1,'files':files,'updates':[]},
                               registry=registry, external_roots=[external], failure=stop_sink)
            recovered = recover_locked(participant, registry=registry, external_roots=[external])
            assert (participant/'SPEC.md').read_text() == 'approved document'
            assert (external/'index').read_bytes() == b'original index'
            assert not archive.exists()
            (external/'index').write_bytes(b'later user index')
            with assertions.assertRaisesRegex(ValueError, 'stale publication token'):
                publish_locked(participant, recovered, {'version':1,'files':files,'updates':[]},
                               registry=registry, external_roots=[external])
            assert (participant/'SPEC.md').read_text() == 'approved document'
            assert (external/'index').read_bytes() == b'later user index'
            ingress = capture_locked(participant, registry=registry, external_roots=[external])
            publish_locked(participant, ingress, {'version':1,'files':files,'updates':[]},
                           registry=registry, external_roots=[external])
            assert not (participant/'SPEC.md').exists()
            assert archive.read_text() == 'approved document'
            assert (external/'index').read_bytes() == b'candidate index'
    print('PASS: trusted sink copies, document deletions and index bytes recover together and reject stale inputs')
    linked_root = Path(work)/'linked-private'
    linked_root.symlink_to(external, target_is_directory=True)
    with locked_feature(participant):
        for roots in ([Path('relative')], [linked_root]):
            with assertions.assertRaisesRegex(ValueError, 'absolute real directory'):
                capture_locked(participant, registry=registry, external_roots=roots)
        with assertions.assertRaisesRegex(ValueError, 'state and internal paths'):
            capture_locked(participant, registry={'archive':str(participant/'feature.json')},
                           external_roots=[participant])
        with assertions.assertRaisesRegex(ValueError, 'escapes'):
            capture_locked(participant, registry={'archive':str(Path(work)/'unregistered')},
                           external_roots=[external])
    print('PASS: external registration rejects symlink roots, escaping files and live-state aliases')

    # A store persist failure must not strand the local transaction: everything local
    # (replacement, state write, journal commit) completes durably, and only then does
    # the caller learn the mirror is behind.
    os.environ.pop('LOOP_SPEC_STORE', None)
    strand = Path(work)/'strand'
    strand.mkdir()
    strand_state = {'slug':'strand','artifacts':{'spec':'SPEC.md'},'artifactPublication':{'version':1,'generation':0,'evidenceEpoch':0,'migration':None,'participantsVersion':1}}
    (strand/'feature.json').write_text(json.dumps(strand_state))
    (strand/'SPEC.md').write_text('original spec')
    failing_store = Path(work)/'strand-failing-store.sh'
    failing_store.write_text('#!/usr/bin/env bash\necho "injected store failure" >&2\nexit 2\n')
    failing_store.chmod(0o755)
    def strand_run(*args, code=0, env=None):
        result = subprocess.run(['bash', str(root/'lib/artifact-publication.sh'), *args, '--feature-dir', str(strand)],
                                 capture_output=True, text=True, env=env)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        return result
    with locked_feature(strand):
        ingress = capture_locked(strand)
        source = stage(strand, 'spec', b'new spec')
    (strand/'strand-token.json').write_text(json.dumps(ingress))
    (strand/'strand-manifest.json').write_text(json.dumps({'version':1,'files':[{'source':source,'target':'spec'}],'updates':[]}))
    failing_env = dict(os.environ, LOOP_SPEC_STORE=str(failing_store))
    result = strand_run('publish', '--token', str(strand/'strand-token.json'), '--manifest', str(strand/'strand-manifest.json'), code=2, env=failing_env)
    assert 'store persist failed' in result.stderr, result.stderr
    assert (strand/'SPEC.md').read_text() == 'new spec'
    assert json.loads((strand/'feature.json').read_text())['artifactPublication']['generation'] == 1
    assert not (strand/'publication-generations/active.json').exists()
    with locked_feature(strand):
        ingress = capture_locked(strand)
        source = stage(strand, 'spec-final', b'final spec')
    (strand/'strand-token.json').write_text(json.dumps(ingress))
    (strand/'strand-manifest.json').write_text(json.dumps({'version':1,'files':[{'source':source,'target':'spec'}],'updates':[]}))
    strand_run('publish', '--token', str(strand/'strand-token.json'), '--manifest', str(strand/'strand-manifest.json'), code=0)
    assert (strand/'SPEC.md').read_text() == 'final spec'
    assert json.loads((strand/'feature.json').read_text())['artifactPublication']['generation'] == 2
    print('PASS: a store persist failure still commits the local transaction and reports itself only afterward')

    # An absolute pointer persisted through a symlinked ancestor (macOS /var -> /private/var)
    # must resolve the same as one stored in the real form -- the feature_dir callers pass
    # in is always the realpath (execute-prepare.sh's `cd ... && pwd -P`), but the pointer
    # a controller persisted earlier can still name the pre-resolution alias.
    sym_real_root = Path(work)/'sym-real'
    sym_real_feature = sym_real_root/'.loop-spec/features/x'
    sym_real_feature.mkdir(parents=True)
    sym_alias_root = Path(work)/'sym-alias'
    sym_alias_root.symlink_to(sym_real_root, target_is_directory=True)
    sym_alias_feature = sym_alias_root/'.loop-spec/features/x'
    sym_state = {'slug':'x','artifacts':{'tasks':str(sym_real_feature/'tasks.json')},
                 'artifactPublication':{'version':1,'generation':0,'evidenceEpoch':0,'migration':None,'participantsVersion':1}}
    (sym_real_feature/'feature.json').write_text(json.dumps(sym_state))
    (sym_real_feature/'tasks.json').write_text('[]')
    with locked_feature(sym_real_feature):
        ingress_via_real_pointer = capture_locked(sym_real_feature)
    assert ingress_via_real_pointer['inputs']['tasks']['path'] == str(sym_real_feature/'tasks.json')
    aliased_state = dict(sym_state, artifacts={'tasks':str(sym_alias_feature/'tasks.json')})
    (sym_real_feature/'feature.json').write_text(json.dumps(aliased_state))
    with locked_feature(sym_real_feature):
        ingress_via_alias_pointer = capture_locked(sym_real_feature)
    assert ingress_via_alias_pointer['inputs']['tasks']['path'] == str(sym_real_feature/'tasks.json')
    assert ingress_via_alias_pointer['inputs']['tasks']['hash'] == ingress_via_real_pointer['inputs']['tasks']['hash']
    print('PASS: an absolute pointer stored in its real form or through a symlinked ancestor both resolve to the real path')

    sym_escape_target = Path(work)/'sym-escape-target'
    sym_escape_target.mkdir()
    (sym_escape_target/'tasks.json').write_text('[]')
    sym_escape_link = sym_real_root/'escape-link'
    sym_escape_link.symlink_to(sym_escape_target, target_is_directory=True)
    escaping_state = dict(sym_state, artifacts={'tasks':str(sym_escape_link/'tasks.json')})
    (sym_real_feature/'feature.json').write_text(json.dumps(escaping_state))
    with locked_feature(sym_real_feature):
        with assertions.assertRaisesRegex(ValueError, 'escapes'):
            capture_locked(sym_real_feature)
    (sym_real_feature/'feature.json').write_text(json.dumps(sym_state))
    print('PASS: a symlink that genuinely escapes the feature roots is still rejected')
PYTEST
