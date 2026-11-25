import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'xray_2go.sh'
ANSI = re.compile(r'\x1b\[[0-9;]*m')

class MenuRegression(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='xray2go-menu-')
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)
        for n in ('home', 'init', 'systemd'):
            (self.d/n).mkdir()

    def shell(self, body, input=''):
        setup = '''
source "$SCRIPT"
work_dir="$CASE/home"; config_dir="$work_dir/config.json"
client_dir="$work_dir/url.txt"; state_file="$work_dir/state.json"
init_dir="$CASE/init"; systemd_dir="$CASE/systemd"
argox_config="$CASE/argox.json"
service_status() { return 1; }
'''
        r = subprocess.run(['bash','-c',setup+body], input=input, capture_output=True, text=True,
                           env={**os.environ,'SCRIPT':str(SCRIPT),'CASE':str(self.d)},timeout=5)
        self.assertEqual(r.returncode,0,r.stderr)
        return r.stdout+r.stderr

    def installed(self):
        for n in ('.installed','xray','config.json','state.json','url.txt'):
            (self.d/'home'/n).write_text('{}')
        (self.d/'home'/'xray').chmod(0o700)
        for n in ('core','tunnel','sub','sync'):
            (self.d/'init'/('xray2go-'+n)).write_text('# Managed by shadowxhero/xray-2go\n')

    def test_absent_only_shows_install_help_exit_with_colors(self):
        out=self.shell('render_menu\n'); plain=ANSI.sub('',out)
        self.assertIn('\x1b[',out)
        self.assertIn('未安装',plain)
        self.assertIn('1. 新安装',plain)
        self.assertIn('h. 帮助',plain)
        self.assertNotIn('修改 RAW',plain)
        self.assertNotIn('17. 卸载',plain)
        self.assertNotIn('已停止',plain)

    def test_hidden_edit_option_cannot_execute_on_absent_installation(self):
        out=self.shell('set_direct_port() { echo EDIT_EXECUTED; }\nmenu\n',input='5\n0\n')
        self.assertNotIn('EDIT_EXECUTED',out)
        self.assertIn('当前安装状态不可用',ANSI.sub('',out))

    def test_old_installation_only_offers_migration(self):
        for n in ('xray','config.json','url.txt'): (self.d/'home'/n).write_text('{}')
        (self.d/'home'/'xray').chmod(0o700)
        (self.d/'init'/'xray').write_text('command="'+str(self.d/'home'/'xray')+'"\n')
        plain=ANSI.sub('',self.shell('render_menu\n'))
        self.assertIn('旧版安装',plain)
        self.assertIn('2. 升级/从 Caddy 迁移',plain)
        self.assertNotIn('1. 新安装',plain)
        self.assertNotIn('修改节点名称',plain)

    def test_partial_installation_is_not_reported_as_stopped(self):
        (self.d/'home'/'config.json').write_text('{}')
        plain=ANSI.sub('',self.shell('render_menu\n'))
        self.assertIn('安装不完整',plain)
        self.assertNotIn('1. 新安装',plain)
        self.assertNotIn('已停止',plain)
        self.assertNotIn('修改节点名称',plain)

    def test_installed_stopped_services_keep_management_options(self):
        self.installed()
        plain=ANSI.sub('',self.shell('render_menu\n'))
        self.assertIn('已安装',plain)
        self.assertIn('已停止',plain)
        self.assertIn('4. 协议管理（增删节点）',plain)
        self.assertIn('5. 修改节点名称',plain)
        self.assertIn('17. 卸载',plain)
        self.assertNotIn('1. 新安装',plain)

    def test_running_and_missing_service_have_distinct_labels(self):
        self.installed()
        out=self.shell('service_status() { [ "$1" = xray2go-core ]; }\nshow_status\n')
        self.assertIn('运行中',ANSI.sub('',out))
        (self.d/'init'/'xray2go-sub').unlink()
        out=self.shell('show_status\n')
        self.assertIn('未安装',ANSI.sub('',out))
        self.assertIn('安装不完整',ANSI.sub('',out))

    def test_foreign_argox_is_not_treated_as_this_project(self):
        (self.d/'argox.json').write_text('{}')
        plain=ANSI.sub('',self.shell('render_menu\n'))
        self.assertIn('ArgoX',plain)
        self.assertNotIn('1. 新安装',plain)
        self.assertNotIn('修改节点名称',plain)
        self.assertIn('未安装',plain)

    def test_menu_eof_exits_instead_of_looping(self):
        self.shell('menu\n')

if __name__=='__main__': unittest.main(verbosity=2)
