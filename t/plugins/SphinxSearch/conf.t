use File::Spec;
BEGIN {
    my $mt_home = $ENV{MT_HOME} || '';
    unshift @INC, File::Spec->catdir ($mt_home, 'lib'), File::Spec->catdir ($mt_home, 'extlib');
}

use Test::More tests => 9;

# Load MT, but it needs to be an MT::App to actually load tmpls :-/
use MT;
use MT::App;
my $mt = MT::App->instance or die MT::App->errstr;

my $plugin = MT::Plugin::SphinxSearch->instance;
ok ($plugin, "Plugin loaded successfully");

# fake the plugin config data

my $pd = $plugin->get_config_obj ('system');

my $tmpl = $plugin->_gen_sphinx_conf_tmpl;
ok ($tmpl, "Template successfully generated");

my $db_host = $mt->config->DBHost;
like ($plugin->_gen_sphinx_conf_tmpl->output, qr/sql_host\s*=\s*$db_host/, "Configured db host value successfully set");

$pd->data ({ db_host => 'testing_db_host_value' });
like ($plugin->_gen_sphinx_conf_tmpl->output, qr/sql_host\s*=\s*testing_db_host_value/, "Alternate database host value successfully set");

my $db_user = $mt->config->DBUser;
like ($plugin->_gen_sphinx_conf_tmpl->output, qr/sql_user\s*=\s*$db_user/, "Configured db user value successfully set");

$pd->data ({ db_user => 'testing_db_user_value' });
like ($plugin->_gen_sphinx_conf_tmpl->output, qr/sql_user\s*=\s*testing_db_user_value/, "Alternate database user value successfully set");

my $db_pass = $mt->config->DBPass;
like ($plugin->_gen_sphinx_conf_tmpl->output, qr/sql_pass\s*=\s*$db_pass/, "Configured db password value successfully set");

$pd->data ({ db_pass => 'testing_db_pass_value' });
like ($plugin->_gen_sphinx_conf_tmpl->output, qr/sql_pass\s*=\s*testing_db_pass_value/, "Alternate database password value successfully set");

$pd->data ({ db_pass => 'testing_with_#_value' });
like ($plugin->_gen_sphinx_conf_tmpl->output, qr/sql_pass\s*=\s*testing_with_\\#_value/, "Alternate database password with # value successfully set");
