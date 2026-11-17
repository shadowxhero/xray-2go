import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT=Path(__file__).resolve().parents[1]/'xray_2go.sh'

class OnlineUpdateRegression(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='xray2go-update-')
        self.addCleanup(self.tmp.cleanup)
        self.d=Path(self.tmp.name)
        self.home=self.d/'home';self.home.mkdir()
        self.old=SCRIPT.read_bytes()
        (self.home/'runtime.sh').write_bytes(self.old)
        (self.home/'runtime.sh').chmod(0o700)
        (self.home/'.installed').touch()
        (self.home/'state.json').write_text('{"name":"KeepMe"}')
        (self.home/'config.json').write_text('{"keep":"authentication"}')
        candidate=SCRIPT.read_text()
        import re
        candidate=re.sub(r'^SCRIPT_VERSION=.*$', 'SCRIPT_VERSION=9.0.0', candidate, flags=re.M)
        (self.d/'candidate.sh').write_text(candidate)

    def shell(self,body,ok=True):
        setup='''
source "$SCRIPT"
work_dir="$CASE/home"; state_file="$work_dir/state.json"; config_dir="$work_dir/config.json"
fetch_latest_script() { cp "$CASE/candidate.sh" "$1"; }
service_action() { echo UNEXPECTED_SERVICE_CHANGE;return 1; }
'''
        r=subprocess.run(['bash','-c',setup+body],env={**os.environ,'SCRIPT':str(SCRIPT),'CASE':str(self.d)},text=True,capture_output=True,timeout=8)
        if ok:self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        return r

    def test_new_script_is_saved_without_restarting_services_or_changing_config(self):
        out=self.shell('online_update\n').stdout
        self.assertNotIn('UNEXPECTED_SERVICE_CHANGE',out)
        self.assertEqual((self.home/'runtime.sh').read_bytes(),(self.d/'candidate.sh').read_bytes())
        self.assertEqual((self.home/'runtime.sh').stat().st_mode & 0o777,0o700)
        self.assertEqual((self.home/'state.json').read_text(),'{"name":"KeepMe"}')
        self.assertEqual((self.home/'config.json').read_text(),'{"keep":"authentication"}')
        backups=list((self.home/'backups').glob('script-update-*/runtime.sh'))
        self.assertEqual(len(backups),1)
        self.assertEqual(backups[0].read_bytes(),self.old)

    def test_network_failure_keeps_previous_runtime(self):
        r=self.shell('fetch_latest_script() { printf partial > "$1";return 22; }\nonline_update\n',ok=False)
        self.assertNotEqual(r.returncode,0)
        self.assertEqual((self.home/'runtime.sh').read_bytes(),self.old)

    def test_syntax_error_and_unrelated_download_are_rejected(self):
        for invalid in ('#!/bin/bash\nSCRIPT_VERSION=9.0.0\nif then\n','#!/bin/bash\nSCRIPT_VERSION=9.0.0\necho unrelated\n'):
            (self.d/'candidate.sh').write_text(invalid)
            r=self.shell('online_update\n',ok=False)
            self.assertNotEqual(r.returncode,0)
            self.assertEqual((self.home/'runtime.sh').read_bytes(),self.old)

    def test_downloaded_candidate_is_not_executed_during_verification(self):
        candidate=(self.d/'candidate.sh').read_text()
        candidate+='\ntouch "'+str(self.d/'must-not-exist')+'"\n'
        (self.d/'candidate.sh').write_text(candidate)
        self.shell('online_update\n')
        self.assertFalse((self.d/'must-not-exist').exists())

    def test_downgrade_is_rejected(self):
        candidate=(self.d/'candidate.sh').read_text().replace('SCRIPT_VERSION=9.0.0','SCRIPT_VERSION=0.0.1')
        (self.d/'candidate.sh').write_text(candidate)
        r=self.shell('online_update\n',ok=False)
        self.assertNotEqual(r.returncode,0)
        self.assertEqual((self.home/'runtime.sh').read_bytes(),self.old)

    def test_identical_release_is_noop(self):
        (self.d/'candidate.sh').write_bytes(self.old)
        self.shell('online_update\n')
        self.assertEqual((self.home/'runtime.sh').read_bytes(),self.old)
        self.assertFalse((self.home/'backups').exists())

    def test_installed_menu_update_does_not_enter_service_repair(self):
        r=self.shell('''
installation_state() { echo installed; }
render_menu() { :; }
reading() { printf -v "$2" 2; }
online_update() { echo ONLINE_UPDATE_CALLED; }
upgrade_installation() { echo UNEXPECTED_REPAIR;return 1; }
menu
''')
        self.assertIn('ONLINE_UPDATE_CALLED',r.stdout)
        self.assertNotIn('UNEXPECTED_REPAIR',r.stdout)

    def test_repair_alias_keeps_local_behavior_without_downloading(self):
        r=self.shell('''
resolve_self() { :; }
upgrade_installation() { echo LOCAL_REPAIR_CALLED; }
fetch_latest_script() { echo UNEXPECTED_DOWNLOAD;return 1; }
main --repair
''')
        self.assertIn('LOCAL_REPAIR_CALLED',r.stdout)
        self.assertNotIn('UNEXPECTED_DOWNLOAD',r.stdout)

    def test_absent_installation_cannot_be_updated(self):
        (self.home/'.installed').unlink()
        r=self.shell('online_update\n',ok=False)
        self.assertNotEqual(r.returncode,0)
        self.assertEqual((self.home/'runtime.sh').read_bytes(),self.old)

if __name__=='__main__':unittest.main(verbosity=2)
