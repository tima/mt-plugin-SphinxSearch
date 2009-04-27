use File::Spec;
BEGIN {
    my $mt_home = $ENV{MT_HOME} || '';
    unshift @INC, File::Spec->catdir ($mt_home, 'lib'), File::Spec->catdir ($mt_home, 'extlib');
}

use lib 't/lib', 'lib', 'extlib';
use Test::More tests => 15;

use MT::Test qw( :db :data );
# Load MT, but it needs to be an MT::App to actually load tmpls :-/
use MT;
use MT::App;
my $mt = MT::App->instance or die MT::App->errstr;

my $plugin = MT::Plugin::SphinxSearch->instance;
ok ($plugin, "Plugin loaded successfully");

# grab the plugin config and blank it out
my $pd = $plugin->get_config_obj ('system');
$pd->data ({});

require_ok('SphinxSearch::Config');

my $tmpl = SphinxSearch::Config->_gen_sphinx_conf_tmpl;
ok ($tmpl, "Template successfully generated");

my $db_host = $mt->config->DBHost;
like (SphinxSearch::Config->_gen_sphinx_conf_tmpl->output, qr/sql_host\s*=\s*$db_host/, "Configured db host value successfully set");

$pd->data ({ db_host => 'testing_db_host_value' });
like (SphinxSearch::Config->_gen_sphinx_conf_tmpl->output, qr/sql_host\s*=\s*testing_db_host_value/, "Alternate database host value successfully set");

my $db_user = $mt->config->DBUser;
like (SphinxSearch::Config->_gen_sphinx_conf_tmpl->output, qr/sql_user\s*=\s*$db_user/, "Configured db user value successfully set");

$pd->data ({ db_user => 'testing_db_user_value' });
like (SphinxSearch::Config->_gen_sphinx_conf_tmpl->output, qr/sql_user\s*=\s*testing_db_user_value/, "Alternate database user value successfully set");

my $db_pass = $mt->config->DBPass;
like (SphinxSearch::Config->_gen_sphinx_conf_tmpl->output, qr/sql_pass\s*=\s*$db_pass/, "Configured db password value successfully set");

$pd->data ({ db_pass => 'testing_db_pass_value' });
like (SphinxSearch::Config->_gen_sphinx_conf_tmpl->output, qr/sql_pass\s*=\s*testing_db_pass_value/, "Alternate database password value successfully set");

$pd->data ({ db_pass => 'testing_with_#_value' });
like (SphinxSearch::Config->_gen_sphinx_conf_tmpl->output, qr/sql_pass\s*=\s*testing_with_\\#_value/, "Alternate database password with # value successfully set");

my @data = ([ 5, 1 ]);
{
    local $SIG{__WARN__} = sub {};
    require MT::Entry;
    *MT::Entry::count_group_by = sub {
        return sub {
            my $d = shift @data;
            return if (!$d);
            @$d;
        };
    };
}
like (SphinxSearch::Config->_gen_sphinx_conf_tmpl->output, qr/max_matches\s*=\s*1000/, "Default max_matches value");

@data = ([ 1500, 1 ]);
my $value = int (1.5 * 1500);
like (SphinxSearch::Config->_gen_sphinx_conf_tmpl->output, qr/max_matches\s*=\s*$value/, "1.5 times max # entries max_matches value");

$pd->data ({ use_indexer_tasks => 0 });
require MT::TheSchwartz::Job;
is (MT::TheSchwartz::Job->count, 0, "No jobs in the queue");

$plugin->sphinx_indexer_task ('main');

is (MT::TheSchwartz::Job->count, 0, "No jobs were added");

$pd->data ({ use_indexer_tasks => 1 });
MT->config->UseSphinxTasks (1);

$plugin->sphinx_indexer_task ('main');

is (MT::TheSchwartz::Job->count, 1, "One job was added");