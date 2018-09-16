package Torb::Web;
use strict;
use warnings;
use utf8;

use Kossy;

use JSON::XS 3.00;
use DBIx::Sunny;
use Plack::Session;
use Time::Moment;
use File::Spec;
use List::Util qw(first shuffle);

filter login_required => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;

        my $user = $self->get_login_user($c);
        return $self->res_error($c, login_required => 401) unless $user;

        $app->($self, $c);
    };
};

filter fillin_user => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;

        my $user = $self->get_login_user($c);
        $c->stash->{user} = $user if $user;

        $app->($self, $c);
    };
};

filter allow_json_request => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;
        $c->env->{'kossy.request.parse_json_body'} = 1;
        $app->($self, $c);
    };
};

sub dbh {
    my $self = shift;
    $self->{_dbh} ||= do {
        my $dsn = "dbi:mysql:database=$ENV{DB_DATABASE};host=$ENV{DB_HOST};port=$ENV{DB_PORT}";
        DBIx::Sunny->connect($dsn, $ENV{DB_USER}, $ENV{DB_PASS}, {
            mysql_enable_utf8mb4 => 1,
            mysql_auto_reconnect => 1,
            # TODO: replace mysqld's sql_mode setting and remove following codes
            Callbacks => {
                connected => sub {
                    my $dbh = shift;
                    $dbh->do('SET SESSION sql_mode="STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"');
                    return;
                },
            },
        });
    };
}

get '/' => [qw/fillin_user/] => sub {
    my ($self, $c) = @_;

    my @events = map { $self->sanitize_event($_) } $self->get_events();
    return $c->render('index.tx', {
        events      => \@events,
        encode_json => sub { $c->escape_json(JSON::XS->new->encode(@_)) },
    });
};

get '/initialize' => sub {
    my ($self, $c) = @_;

    system+File::Spec->catfile($self->root_dir, '../../db/init.sh');

    return $c->req->new_response(204, [], '');
};

post '/api/users' => [qw/allow_json_request/] => sub {
    my ($self, $c) = @_;
    my $nickname   = $c->req->body_parameters->get('nickname');
    my $login_name = $c->req->body_parameters->get('login_name');
    my $password   = $c->req->body_parameters->get('password');

    my ($user_id, $error);

    my $res;
    my $txn = $self->dbh->txn_scope();
    eval {
        my $duplicated = $self->dbh->select_one('SELECT * FROM users WHERE login_name = ?', $login_name);
        if ($duplicated) {
            $res = $self->res_error($c, duplicated => 409);
            $txn->rollback();
            return;
        }

        $self->dbh->query('INSERT INTO users (login_name, pass_hash, nickname) VALUES (?, SHA2(?, 256), ?)', $login_name, $password, $nickname);
        $user_id = $self->dbh->last_insert_id();
        $txn->commit();
    };
    if ($@) {
        warn "rollback by: $@";
        $txn->rollback();
        $res = $self->res_error($c);
    }
    return $res if $res;

    $res = $c->render_json({ id => 0+$user_id, nickname => $nickname });
    $res->status(201);
    return $res;
};

sub get_login_user {
    my ($self, $c) = @_;

    my $session = Plack::Session->new($c->env);
    my $user_id = $session->get('user_id');
    return unless $user_id;
    return $self->dbh->select_row('SELECT id, nickname FROM users WHERE id = ?', $user_id);
}

get '/api/users/{id}' => [qw/login_required/] => sub {
    my ($self, $c) = @_;

    my $user = $self->dbh->select_row('SELECT id, nickname FROM users WHERE id = ?', $c->args->{id});
    if ($user->{id} != $self->get_login_user($c)->{id}) {
        return $self->res_error($c, forbidden => 403);
    }

    my @recent_reservations;
    {
        my $rows = $self->dbh->select_all('SELECT r.*, s.rank AS sheet_rank, s.num AS sheet_num FROM reservations r INNER JOIN sheets s ON s.id = r.sheet_id WHERE r.user_id = ? ORDER BY IFNULL(r.canceled_at, r.reserved_at) DESC LIMIT 5', $user->{id});
        for my $row (@$rows) {
            my $event = $self->get_event($row->{event_id});

            my $reservation = {
                id          => 0+$row->{id},
                event       => $event,
                sheet_rank  => $row->{sheet_rank},
                sheet_num   => 0+$row->{sheet_num},
                price       => $event->{sheets}->{$row->{sheet_rank}}->{price},
                reserved_at => Time::Moment->from_string("$row->{reserved_at}Z", lenient => 1)->epoch(),
                canceled_at => $row->{canceled_at} ? Time::Moment->from_string("$row->{canceled_at}Z", lenient => 1)->epoch() : undef,
            };
            push @recent_reservations => $reservation;

            delete $event->{sheets};
            delete $event->{total};
            delete $event->{remains};
            delete $event->{price};
        }
    };
    $user->{recent_reservations} = \@recent_reservations;
    $user->{total_price} = 0+$self->dbh->select_one('SELECT IFNULL(SUM(e.price + s.price), 0) FROM reservations r INNER JOIN sheets s ON s.id = r.sheet_id INNER JOIN events e ON e.id = r.event_id WHERE r.user_id = ? AND r.canceled_at IS NULL', $user->{id});

    my @recent_events;
    {
        my $rows = $self->dbh->select_all('SELECT event_id FROM reservations WHERE user_id = ? GROUP BY event_id ORDER BY MAX(IFNULL(canceled_at, reserved_at)) DESC LIMIT 5', $user->{id});
        for my $row (@$rows) {
            my $event = $self->get_event($row->{event_id});
            delete $event->{sheets}->{$_}->{detail} for keys %{ $event->{sheets} };

            push @recent_events => $event;
        }
    }
    $user->{recent_events} = \@recent_events;

    return $c->render_json($user);
};

post '/api/actions/login' => [qw/allow_json_request/] => sub {
    my ($self, $c) = @_;
    my $login_name = $c->req->body_parameters->get('login_name');
    my $password   = $c->req->body_parameters->get('password');

    my $user      = $self->dbh->select_row('SELECT * FROM users WHERE login_name = ?', $login_name);
    my $pass_hash = $self->dbh->select_one('SELECT SHA2(?, 256)', $password);
    return $self->res_error($c, authentication_failed => 401) if !$user || $pass_hash ne $user->{pass_hash};

    my $session = Plack::Session->new($c->env);
    $session->set('user_id' => $user->{id});

    $user = $self->get_login_user($c);
    return $c->render_json($user);
};

post '/api/actions/logout' => [qw/login_required/] => sub {
    my ($self, $c) = @_;
    my $session = Plack::Session->new($c->env);
    $session->remove('user_id');
    return $c->req->new_response(204, [], '');
};

get '/api/events' => sub {
    my ($self, $c) = @_;
    my @events = map { $self->sanitize_event($_) } $self->get_events();
    return $c->render_json(\@events);
};

get '/api/events/{id}' => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};

    my $user = $self->get_login_user($c) || {};
    my $event = $self->get_event($event_id, $user->{id});
    return $self->res_error($c, not_found => 404) if !$event || !$event->{public};

    $event = $self->sanitize_event($event);
    return $c->render_json($event);
};

sub get_events {
    my ($self, $where) = @_;
    $where ||= sub { $_->{public_fg} };

    my $txn = $self->dbh->txn_scope();

    my @events;
    my @event_ids = map { $_->{id} } grep $where->($_), @{ $self->dbh->select_all('SELECT * FROM events ORDER BY id ASC') };
    for my $event_id (@event_ids) {
        my $event = $self->get_event($event_id);

        delete $event->{sheets}->{$_}->{detail} for keys %{ $event->{sheets} };
        push @events => $event;
    }

    $txn->commit();

    return @events;
}

my $sheets;

sub get_event {
    my ($self, $event_id, $login_user_id) = @_;

    my $event = $self->dbh->select_row('SELECT * FROM events WHERE id = ?', $event_id);
    return unless $event;

    # zero fill
    $event->{total}   = 0;
    $event->{remains} = 0;
    for my $rank (qw/S A B C/) {
        $event->{sheets}->{$rank}->{total}   = 0;
        $event->{sheets}->{$rank}->{remains} = 0;
    }

    $sheets ||= $self->dbh->select_all('SELECT * FROM sheets ORDER BY `rank`, num');# TODO: ハードコード

    my $reservations_by_sheet_ids = { map { ($_->{sheet_id} => $_) } @{$self->dbh->select_all('SELECT * FROM reservations WHERE event_id = ? AND canceled_at IS NULL GROUP BY event_id, sheet_id HAVING reserved_at = MIN(reserved_at)', $event->{id})} };
    for my $_sheet (@$sheets) {
        my $sheet = { %$_sheet };
        $event->{sheets}->{$sheet->{rank}}->{price} ||= $event->{price} + $sheet->{price};

        $event->{total} += 1;
        $event->{sheets}->{$sheet->{rank}}->{total} += 1;

        my $reservation = $reservations_by_sheet_ids->{$sheet->{id}};
        if ($reservation) {
            $sheet->{mine}        = JSON::XS::true if $login_user_id && $reservation->{user_id} == $login_user_id;
            $sheet->{reserved}    = JSON::XS::true;
            $sheet->{reserved_at} = Time::Moment->from_string($reservation->{reserved_at}.'Z', lenient => 1)->epoch;
        } else {
            $event->{remains} += 1;
            $event->{sheets}->{$sheet->{rank}}->{remains} += 1;
        }

        push @{ $event->{sheets}->{$sheet->{rank}}->{detail} } => $sheet;

        delete $sheet->{id};
        delete $sheet->{price};
        delete $sheet->{rank};
    }

    $event->{public} = delete $event->{public_fg} ? JSON::XS::true : JSON::XS::false;
    $event->{closed} = delete $event->{closed_fg} ? JSON::XS::true : JSON::XS::false;

    return $event;
}

sub sanitize_event {
    my ($self, $event) = @_;
    my $sanitized = {%$event}; # shallow clone
    delete $sanitized->{price};
    delete $sanitized->{public};
    delete $sanitized->{closed};
    return $sanitized;
}

post '/api/events/{id}/actions/reserve' => [qw/allow_json_request login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};
    my $rank = $c->req->body_parameters->get('sheet_rank');

    my $user  = $self->get_login_user($c);
    my $event = $self->get_event($event_id, $user->{id});
    return $self->res_error($c, invalid_event => 404) unless $event && $event->{public};
    return $self->res_error($c, invalid_rank => 400)  unless $self->validate_rank($rank);

    my $sheet;
    my $reservation_id;
    while (1) {
        $sheet = [ shuffle @{ $self->dbh->select_all('SELECT * FROM sheets WHERE id NOT IN (SELECT sheet_id FROM reservations WHERE event_id = ? AND canceled_at IS NULL FOR UPDATE) AND `rank` = ?', $event->{id}, $rank) } ]->[0];
        return $self->res_error($c, sold_out => 409) unless $sheet;

        my $txn = $self->dbh->txn_scope();
        eval {
            $self->dbh->query('INSERT INTO reservations (event_id, sheet_id, user_id, reserved_at) VALUES (?, ?, ?, ?)', $event->{id}, $sheet->{id}, $user->{id}, Time::Moment->now_utc->strftime('%F %T%f'));
            $reservation_id = $self->dbh->last_insert_id();
            $txn->commit();
        };
        if ($@) {
            $txn->rollback();
            warn "re-try: rollback by $@";
            next; # retry
        }

        last;
    }

    my $res = $c->render_json({
        id         => 0+$reservation_id,
        sheet_rank => $rank,
        sheet_num  => 0+$sheet->{num},
    });
    $res->status(202);
    return $res;
};

router ['DELETE'] => '/api/events/{id}/sheets/{rank}/{num}/reservation' => [qw/login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};
    my $rank     = $c->args->{rank};
    my $num      = $c->args->{num};

    my $user  = $self->get_login_user($c);
    my $event = $self->get_event($event_id, $user->{id});
    return $self->res_error($c, invalid_event => 404) unless $event && $event->{public};
    return $self->res_error($c, invalid_rank => 404)  unless $self->validate_rank($rank);

    my $sheet = $self->dbh->select_row('SELECT * FROM sheets WHERE `rank` = ? AND num = ?', $rank, $num);
    return $self->res_error($c, invalid_sheet => 404)  unless $sheet;

    my $res;
    my $txn = $self->dbh->txn_scope();
    eval {
        my $reservation_for_id = $self->dbh->select_row('SELECT * FROM reservations WHERE event_id = ? AND sheet_id = ? AND user_id = ? AND canceled_at IS NULL GROUP BY event_id HAVING reserved_at = MIN(reserved_at)', $event->{id}, $sheet->{id}, $user->{id});

        unless ($reservation_for_id) {
            $res = $self->res_error($c, not_reserved => 400);
            $txn->rollback();
            return;
        }
        my $reservation = $self->dbh->select_row('SELECT * FROM reservations WHERE id = ? FOR UPDATE', $reservation_for_id->{id});

        unless ($reservation) {
            $res = $self->res_error($c, not_reserved => 400);
            $txn->rollback();
            return;
        }
        if ($reservation->{user_id} != $user->{id}) {
            $res = $self->res_error($c, not_permitted => 403);
            $txn->rollback();
            return;
        }

        $self->dbh->query('UPDATE reservations SET canceled_at = ? WHERE id = ?', Time::Moment->now_utc->strftime('%F %T%f'), $reservation->{id});
        $txn->commit();
    };
    if ($@) {
        warn "rollback by: $@";
        $txn->rollback();
        $res = $self->res_error($c);
    }
    return $res if $res;

    return $c->req->new_response(204, [], '');
};

sub validate_rank {
    my ($self, $rank) = @_;
    return $self->dbh->select_one('SELECT COUNT(*) FROM sheets WHERE `rank` = ?', $rank);
}

filter admin_login_required => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;
        my $session = Plack::Session->new($c->env);

        my $administrator = $self->get_login_administrator($c);
        return $self->res_error($c, admin_login_required => 401) unless $administrator;

        $app->($self, $c);
    };
};

filter fillin_administrator => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;

        my $administrator = $self->get_login_administrator($c);
        $c->stash->{administrator} = $administrator if $administrator;

        $app->($self, $c);
    };
};

get '/admin/' => [qw/fillin_administrator/] => sub {
    my ($self, $c) = @_;

    my @events;
    @events = $self->get_events(sub { $_ }) if $c->stash->{administrator};

    return $c->render('admin.tx', {
        events      => \@events,
        encode_json => sub { $c->escape_json(JSON::XS->new->encode(@_)) },
    });
};

post '/admin/api/actions/login' => [qw/allow_json_request/] => sub {
    my ($self, $c) = @_;
    my $login_name = $c->req->body_parameters->get('login_name');
    my $password   = $c->req->body_parameters->get('password');

    my $administrator = $self->dbh->select_row('SELECT * FROM administrators WHERE login_name = ?', $login_name);
    my $pass_hash     = $self->dbh->select_one('SELECT SHA2(?, 256)', $password);
    return $self->res_error($c, authentication_failed => 401) if !$administrator || $pass_hash ne $administrator->{pass_hash};

    my $session = Plack::Session->new($c->env);
    $session->set('administrator_id' => $administrator->{id});

    $administrator = $self->get_login_administrator($c);
    return $c->render_json($administrator);
};

post '/admin/api/actions/logout' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $session = Plack::Session->new($c->env);
    $session->remove('administrator_id');
    return $c->req->new_response(204, [], '');
};

sub get_login_administrator {
    my ($self, $c) = @_;
    my $session = Plack::Session->new($c->env);
    my $administrator_id = $session->get('administrator_id');
    return unless $administrator_id;
    return $self->dbh->select_row('SELECT id, nickname FROM administrators WHERE id = ?', $administrator_id);
}

get '/admin/api/events' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;

    my @events = $self->get_events(sub { $_ });
    return $c->render_json(\@events);
};

post '/admin/api/events' => [qw/allow_json_request admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $title  = $c->req->body_parameters->get('title');
    my $public = $c->req->body_parameters->get('public') ? 1 : 0;
    my $price  = $c->req->body_parameters->get('price');

    my $event_id;

    my $txn = $self->dbh->txn_scope();
    eval {
        $self->dbh->query('INSERT INTO events (title, public_fg, closed_fg, price) VALUES (?, ?, 0, ?)', $title, $public, $price);
        $event_id = $self->dbh->last_insert_id();
        $txn->commit();
    };
    if ($@) {
        $txn->rollback();
    }

    my $event = $self->get_event($event_id);
    return $c->render_json($event);
};

get '/admin/api/events/{id}' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};

    my $event = $self->get_event($event_id);
    return $self->res_error($c, not_found => 404) unless $event;

    return $c->render_json($event);
};

post '/admin/api/events/{id}/actions/edit' => [qw/allow_json_request admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};
    my $public = $c->req->body_parameters->get('public') ? 1 : 0;
    my $closed = $c->req->body_parameters->get('closed') ? 1 : 0;
    $public = 0 if $closed;

    my $event = $self->get_event($event_id);
    return $self->res_error($c, not_found => 404) unless $event;

    if ($event->{closed}) {
        return $self->res_error($c, cannot_edit_closed_event => 400);
    } elsif ($event->{public} && $closed) {
        return $self->res_error($c, cannot_close_public_event => 400);
    }

    my $txn = $self->dbh->txn_scope();
    eval {
        $self->dbh->query('UPDATE events SET public_fg = ?, closed_fg = ? WHERE id = ?', $public, $closed, $event->{id});
        $txn->commit();
    };
    if ($@) {
        $txn->rollback();
    }

    $event = $self->get_event($event_id);
    return $c->render_json($event);
};

get '/admin/api/reports/events/{id}/sales' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};
    my $event = $self->get_event($event_id);

    my @reports;

    my $reservations = $self->dbh->select_all('SELECT r.*, s.rank AS sheet_rank, s.num AS sheet_num, s.price AS sheet_price, e.price AS event_price FROM reservations r INNER JOIN sheets s ON s.id = r.sheet_id INNER JOIN events e ON e.id = r.event_id WHERE r.event_id = ? ORDER BY reserved_at ASC', $event->{id});
    for my $reservation (@$reservations) {
        my $report = {
            reservation_id => $reservation->{id},
            event_id       => $event->{id},
            rank           => $reservation->{sheet_rank},
            num            => $reservation->{sheet_num},
            user_id        => $reservation->{user_id},
            sold_at        => Time::Moment->from_string("$reservation->{reserved_at}Z", lenient => 1)->to_string(),
            canceled_at    => $reservation->{canceled_at} ? Time::Moment->from_string("$reservation->{canceled_at}Z", lenient => 1)->to_string() : '',
            price          => $reservation->{event_price} + $reservation->{sheet_price},
        };

        push @reports => $report;
    }

    return $self->render_report_csv($c, \@reports);
};

get '/admin/api/reports/sales' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;

    my @reports;

    $self->dbh->select_row("SELECT GET_LOCK('reports', 10);");
    my $reservations = $self->dbh->select_all('SELECT r.*, s.rank AS sheet_rank, s.num AS sheet_num, s.price AS sheet_price, e.id AS event_id, e.price AS event_price FROM reservations r INNER JOIN sheets s ON s.id = r.sheet_id INNER JOIN events e ON e.id = r.event_id ORDER BY reserved_at ASC');
    my @keys = qw/reservation_id event_id rank num price user_id sold_at canceled_at/;
    my $body = "\0" x 15000000;
    $body = join(',', @keys) . "\n";

    for my $reservation (@$reservations) {
        $body .= join(
            ',',
            $reservation->{id},
            $reservation->{event_id},
            $reservation->{sheet_rank},
            $reservation->{sheet_num},
            $reservation->{event_price} + $reservation->{sheet_price},
            $reservation->{user_id},
            Time::Moment->from_string("$reservation->{reserved_at}Z", lenient => 1)->to_string(),
            $reservation->{canceled_at} ? Time::Moment->from_string("$reservation->{canceled_at}Z", lenient => 1)->to_string() : '',
        ) . "\n";
        # my $report = {
        #     reservation_id => $reservation->{id},
        #     event_id       => $reservation->{event_id},
        #     rank           => $reservation->{sheet_rank},
        #     num            => $reservation->{sheet_num},
        #     user_id        => $reservation->{user_id},
        #     sold_at        => Time::Moment->from_string("$reservation->{reserved_at}Z", lenient => 1)->to_string(),
        #     canceled_at    => $reservation->{canceled_at} ? Time::Moment->from_string("$reservation->{canceled_at}Z", lenient => 1)->to_string() : '',
        #     price          => $reservation->{event_price} + $reservation->{sheet_price},
        # };
        # push @reports => $report;
    }
    $self->dbh->select_row("select RELEASE_LOCK('reports')");

    my $res = $c->req->new_response(200, [
        'Content-Type'        => 'text/csv; charset=UTF-8',
        'Content-Disposition' => 'attachment; filename="report.csv"',
    ], $body);
    return $res;
    # return $self->render_report_csv($c, \@reports);
};

sub render_report_csv {
    my ($self, $c, $reports) = @_;

    my @keys = qw/reservation_id event_id rank num price user_id sold_at canceled_at/;
    my $body = join ',', @keys;
    $body .= "\n";
    for my $report (@$reports) {
        $body .= join ',', @{$report}{@keys};
        $body .= "\n";
    }

    my $res = $c->req->new_response(200, [
        'Content-Type'        => 'text/csv; charset=UTF-8',
        'Content-Disposition' => 'attachment; filename="report.csv"',
    ], $body);
    return $res;
}

sub res_error {
    my ($self, $c, $error, $status) = @_;
    $error  ||= 'unknown';
    $status ||= 500;

    my $res = $c->render_json({ error => $error });
    $res->status($status);
    return $res;
}

1;

__DATA__
id	rank	num	price
1	S	1	5000
2	S	2	5000
3	S	3	5000
4	S	4	5000
5	S	5	5000
6	S	6	5000
7	S	7	5000
8	S	8	5000
9	S	9	5000
10	S	10	5000
11	S	11	5000
12	S	12	5000
13	S	13	5000
14	S	14	5000
15	S	15	5000
16	S	16	5000
17	S	17	5000
18	S	18	5000
19	S	19	5000
20	S	20	5000
21	S	21	5000
22	S	22	5000
23	S	23	5000
24	S	24	5000
25	S	25	5000
26	S	26	5000
27	S	27	5000
28	S	28	5000
29	S	29	5000
30	S	30	5000
31	S	31	5000
32	S	32	5000
33	S	33	5000
34	S	34	5000
35	S	35	5000
36	S	36	5000
37	S	37	5000
38	S	38	5000
39	S	39	5000
40	S	40	5000
41	S	41	5000
42	S	42	5000
43	S	43	5000
44	S	44	5000
45	S	45	5000
46	S	46	5000
47	S	47	5000
48	S	48	5000
49	S	49	5000
50	S	50	5000
51	A	1	3000
52	A	2	3000
53	A	3	3000
54	A	4	3000
55	A	5	3000
56	A	6	3000
57	A	7	3000
58	A	8	3000
59	A	9	3000
60	A	10	3000
61	A	11	3000
62	A	12	3000
63	A	13	3000
64	A	14	3000
65	A	15	3000
66	A	16	3000
67	A	17	3000
68	A	18	3000
69	A	19	3000
70	A	20	3000
71	A	21	3000
72	A	22	3000
73	A	23	3000
74	A	24	3000
75	A	25	3000
76	A	26	3000
77	A	27	3000
78	A	28	3000
79	A	29	3000
80	A	30	3000
81	A	31	3000
82	A	32	3000
83	A	33	3000
84	A	34	3000
85	A	35	3000
86	A	36	3000
87	A	37	3000
88	A	38	3000
89	A	39	3000
90	A	40	3000
91	A	41	3000
92	A	42	3000
93	A	43	3000
94	A	44	3000
95	A	45	3000
96	A	46	3000
97	A	47	3000
98	A	48	3000
99	A	49	3000
100	A	50	3000
101	A	51	3000
102	A	52	3000
103	A	53	3000
104	A	54	3000
105	A	55	3000
106	A	56	3000
107	A	57	3000
108	A	58	3000
109	A	59	3000
110	A	60	3000
111	A	61	3000
112	A	62	3000
113	A	63	3000
114	A	64	3000
115	A	65	3000
116	A	66	3000
117	A	67	3000
118	A	68	3000
119	A	69	3000
120	A	70	3000
121	A	71	3000
122	A	72	3000
123	A	73	3000
124	A	74	3000
125	A	75	3000
126	A	76	3000
127	A	77	3000
128	A	78	3000
129	A	79	3000
130	A	80	3000
131	A	81	3000
132	A	82	3000
133	A	83	3000
134	A	84	3000
135	A	85	3000
136	A	86	3000
137	A	87	3000
138	A	88	3000
139	A	89	3000
140	A	90	3000
141	A	91	3000
142	A	92	3000
143	A	93	3000
144	A	94	3000
145	A	95	3000
146	A	96	3000
147	A	97	3000
148	A	98	3000
149	A	99	3000
150	A	100	3000
151	A	101	3000
152	A	102	3000
153	A	103	3000
154	A	104	3000
155	A	105	3000
156	A	106	3000
157	A	107	3000
158	A	108	3000
159	A	109	3000
160	A	110	3000
161	A	111	3000
162	A	112	3000
163	A	113	3000
164	A	114	3000
165	A	115	3000
166	A	116	3000
167	A	117	3000
168	A	118	3000
169	A	119	3000
170	A	120	3000
171	A	121	3000
172	A	122	3000
173	A	123	3000
174	A	124	3000
175	A	125	3000
176	A	126	3000
177	A	127	3000
178	A	128	3000
179	A	129	3000
180	A	130	3000
181	A	131	3000
182	A	132	3000
183	A	133	3000
184	A	134	3000
185	A	135	3000
186	A	136	3000
187	A	137	3000
188	A	138	3000
189	A	139	3000
190	A	140	3000
191	A	141	3000
192	A	142	3000
193	A	143	3000
194	A	144	3000
195	A	145	3000
196	A	146	3000
197	A	147	3000
198	A	148	3000
199	A	149	3000
200	A	150	3000
201	B	1	1000
202	B	2	1000
203	B	3	1000
204	B	4	1000
205	B	5	1000
206	B	6	1000
207	B	7	1000
208	B	8	1000
209	B	9	1000
210	B	10	1000
211	B	11	1000
212	B	12	1000
213	B	13	1000
214	B	14	1000
215	B	15	1000
216	B	16	1000
217	B	17	1000
218	B	18	1000
219	B	19	1000
220	B	20	1000
221	B	21	1000
222	B	22	1000
223	B	23	1000
224	B	24	1000
225	B	25	1000
226	B	26	1000
227	B	27	1000
228	B	28	1000
229	B	29	1000
230	B	30	1000
231	B	31	1000
232	B	32	1000
233	B	33	1000
234	B	34	1000
235	B	35	1000
236	B	36	1000
237	B	37	1000
238	B	38	1000
239	B	39	1000
240	B	40	1000
241	B	41	1000
242	B	42	1000
243	B	43	1000
244	B	44	1000
245	B	45	1000
246	B	46	1000
247	B	47	1000
248	B	48	1000
249	B	49	1000
250	B	50	1000
251	B	51	1000
252	B	52	1000
253	B	53	1000
254	B	54	1000
255	B	55	1000
256	B	56	1000
257	B	57	1000
258	B	58	1000
259	B	59	1000
260	B	60	1000
261	B	61	1000
262	B	62	1000
263	B	63	1000
264	B	64	1000
265	B	65	1000
266	B	66	1000
267	B	67	1000
268	B	68	1000
269	B	69	1000
270	B	70	1000
271	B	71	1000
272	B	72	1000
273	B	73	1000
274	B	74	1000
275	B	75	1000
276	B	76	1000
277	B	77	1000
278	B	78	1000
279	B	79	1000
280	B	80	1000
281	B	81	1000
282	B	82	1000
283	B	83	1000
284	B	84	1000
285	B	85	1000
286	B	86	1000
287	B	87	1000
288	B	88	1000
289	B	89	1000
290	B	90	1000
291	B	91	1000
292	B	92	1000
293	B	93	1000
294	B	94	1000
295	B	95	1000
296	B	96	1000
297	B	97	1000
298	B	98	1000
299	B	99	1000
300	B	100	1000
301	B	101	1000
302	B	102	1000
303	B	103	1000
304	B	104	1000
305	B	105	1000
306	B	106	1000
307	B	107	1000
308	B	108	1000
309	B	109	1000
310	B	110	1000
311	B	111	1000
312	B	112	1000
313	B	113	1000
314	B	114	1000
315	B	115	1000
316	B	116	1000
317	B	117	1000
318	B	118	1000
319	B	119	1000
320	B	120	1000
321	B	121	1000
322	B	122	1000
323	B	123	1000
324	B	124	1000
325	B	125	1000
326	B	126	1000
327	B	127	1000
328	B	128	1000
329	B	129	1000
330	B	130	1000
331	B	131	1000
332	B	132	1000
333	B	133	1000
334	B	134	1000
335	B	135	1000
336	B	136	1000
337	B	137	1000
338	B	138	1000
339	B	139	1000
340	B	140	1000
341	B	141	1000
342	B	142	1000
343	B	143	1000
344	B	144	1000
345	B	145	1000
346	B	146	1000
347	B	147	1000
348	B	148	1000
349	B	149	1000
350	B	150	1000
351	B	151	1000
352	B	152	1000
353	B	153	1000
354	B	154	1000
355	B	155	1000
356	B	156	1000
357	B	157	1000
358	B	158	1000
359	B	159	1000
360	B	160	1000
361	B	161	1000
362	B	162	1000
363	B	163	1000
364	B	164	1000
365	B	165	1000
366	B	166	1000
367	B	167	1000
368	B	168	1000
369	B	169	1000
370	B	170	1000
371	B	171	1000
372	B	172	1000
373	B	173	1000
374	B	174	1000
375	B	175	1000
376	B	176	1000
377	B	177	1000
378	B	178	1000
379	B	179	1000
380	B	180	1000
381	B	181	1000
382	B	182	1000
383	B	183	1000
384	B	184	1000
385	B	185	1000
386	B	186	1000
387	B	187	1000
388	B	188	1000
389	B	189	1000
390	B	190	1000
391	B	191	1000
392	B	192	1000
393	B	193	1000
394	B	194	1000
395	B	195	1000
396	B	196	1000
397	B	197	1000
398	B	198	1000
399	B	199	1000
400	B	200	1000
401	B	201	1000
402	B	202	1000
403	B	203	1000
404	B	204	1000
405	B	205	1000
406	B	206	1000
407	B	207	1000
408	B	208	1000
409	B	209	1000
410	B	210	1000
411	B	211	1000
412	B	212	1000
413	B	213	1000
414	B	214	1000
415	B	215	1000
416	B	216	1000
417	B	217	1000
418	B	218	1000
419	B	219	1000
420	B	220	1000
421	B	221	1000
422	B	222	1000
423	B	223	1000
424	B	224	1000
425	B	225	1000
426	B	226	1000
427	B	227	1000
428	B	228	1000
429	B	229	1000
430	B	230	1000
431	B	231	1000
432	B	232	1000
433	B	233	1000
434	B	234	1000
435	B	235	1000
436	B	236	1000
437	B	237	1000
438	B	238	1000
439	B	239	1000
440	B	240	1000
441	B	241	1000
442	B	242	1000
443	B	243	1000
444	B	244	1000
445	B	245	1000
446	B	246	1000
447	B	247	1000
448	B	248	1000
449	B	249	1000
450	B	250	1000
451	B	251	1000
452	B	252	1000
453	B	253	1000
454	B	254	1000
455	B	255	1000
456	B	256	1000
457	B	257	1000
458	B	258	1000
459	B	259	1000
460	B	260	1000
461	B	261	1000
462	B	262	1000
463	B	263	1000
464	B	264	1000
465	B	265	1000
466	B	266	1000
467	B	267	1000
468	B	268	1000
469	B	269	1000
470	B	270	1000
471	B	271	1000
472	B	272	1000
473	B	273	1000
474	B	274	1000
475	B	275	1000
476	B	276	1000
477	B	277	1000
478	B	278	1000
479	B	279	1000
480	B	280	1000
481	B	281	1000
482	B	282	1000
483	B	283	1000
484	B	284	1000
485	B	285	1000
486	B	286	1000
487	B	287	1000
488	B	288	1000
489	B	289	1000
490	B	290	1000
491	B	291	1000
492	B	292	1000
493	B	293	1000
494	B	294	1000
495	B	295	1000
496	B	296	1000
497	B	297	1000
498	B	298	1000
499	B	299	1000
500	B	300	1000
501	C	1	0
502	C	2	0
503	C	3	0
504	C	4	0
505	C	5	0
506	C	6	0
507	C	7	0
508	C	8	0
509	C	9	0
510	C	10	0
511	C	11	0
512	C	12	0
513	C	13	0
514	C	14	0
515	C	15	0
516	C	16	0
517	C	17	0
518	C	18	0
519	C	19	0
520	C	20	0
521	C	21	0
522	C	22	0
523	C	23	0
524	C	24	0
525	C	25	0
526	C	26	0
527	C	27	0
528	C	28	0
529	C	29	0
530	C	30	0
531	C	31	0
532	C	32	0
533	C	33	0
534	C	34	0
535	C	35	0
536	C	36	0
537	C	37	0
538	C	38	0
539	C	39	0
540	C	40	0
541	C	41	0
542	C	42	0
543	C	43	0
544	C	44	0
545	C	45	0
546	C	46	0
547	C	47	0
548	C	48	0
549	C	49	0
550	C	50	0
551	C	51	0
552	C	52	0
553	C	53	0
554	C	54	0
555	C	55	0
556	C	56	0
557	C	57	0
558	C	58	0
559	C	59	0
560	C	60	0
561	C	61	0
562	C	62	0
563	C	63	0
564	C	64	0
565	C	65	0
566	C	66	0
567	C	67	0
568	C	68	0
569	C	69	0
570	C	70	0
571	C	71	0
572	C	72	0
573	C	73	0
574	C	74	0
575	C	75	0
576	C	76	0
577	C	77	0
578	C	78	0
579	C	79	0
580	C	80	0
581	C	81	0
582	C	82	0
583	C	83	0
584	C	84	0
585	C	85	0
586	C	86	0
587	C	87	0
588	C	88	0
589	C	89	0
590	C	90	0
591	C	91	0
592	C	92	0
593	C	93	0
594	C	94	0
595	C	95	0
596	C	96	0
597	C	97	0
598	C	98	0
599	C	99	0
600	C	100	0
601	C	101	0
602	C	102	0
603	C	103	0
604	C	104	0
605	C	105	0
606	C	106	0
607	C	107	0
608	C	108	0
609	C	109	0
610	C	110	0
611	C	111	0
612	C	112	0
613	C	113	0
614	C	114	0
615	C	115	0
616	C	116	0
617	C	117	0
618	C	118	0
619	C	119	0
620	C	120	0
621	C	121	0
622	C	122	0
623	C	123	0
624	C	124	0
625	C	125	0
626	C	126	0
627	C	127	0
628	C	128	0
629	C	129	0
630	C	130	0
631	C	131	0
632	C	132	0
633	C	133	0
634	C	134	0
635	C	135	0
636	C	136	0
637	C	137	0
638	C	138	0
639	C	139	0
640	C	140	0
641	C	141	0
642	C	142	0
643	C	143	0
644	C	144	0
645	C	145	0
646	C	146	0
647	C	147	0
648	C	148	0
649	C	149	0
650	C	150	0
651	C	151	0
652	C	152	0
653	C	153	0
654	C	154	0
655	C	155	0
656	C	156	0
657	C	157	0
658	C	158	0
659	C	159	0
660	C	160	0
661	C	161	0
662	C	162	0
663	C	163	0
664	C	164	0
665	C	165	0
666	C	166	0
667	C	167	0
668	C	168	0
669	C	169	0
670	C	170	0
671	C	171	0
672	C	172	0
673	C	173	0
674	C	174	0
675	C	175	0
676	C	176	0
677	C	177	0
678	C	178	0
679	C	179	0
680	C	180	0
681	C	181	0
682	C	182	0
683	C	183	0
684	C	184	0
685	C	185	0
686	C	186	0
687	C	187	0
688	C	188	0
689	C	189	0
690	C	190	0
691	C	191	0
692	C	192	0
693	C	193	0
694	C	194	0
695	C	195	0
696	C	196	0
697	C	197	0
698	C	198	0
699	C	199	0
700	C	200	0
701	C	201	0
702	C	202	0
703	C	203	0
704	C	204	0
705	C	205	0
706	C	206	0
707	C	207	0
708	C	208	0
709	C	209	0
710	C	210	0
711	C	211	0
712	C	212	0
713	C	213	0
714	C	214	0
715	C	215	0
716	C	216	0
717	C	217	0
718	C	218	0
719	C	219	0
720	C	220	0
721	C	221	0
722	C	222	0
723	C	223	0
724	C	224	0
725	C	225	0
726	C	226	0
727	C	227	0
728	C	228	0
729	C	229	0
730	C	230	0
731	C	231	0
732	C	232	0
733	C	233	0
734	C	234	0
735	C	235	0
736	C	236	0
737	C	237	0
738	C	238	0
739	C	239	0
740	C	240	0
741	C	241	0
742	C	242	0
743	C	243	0
744	C	244	0
745	C	245	0
746	C	246	0
747	C	247	0
748	C	248	0
749	C	249	0
750	C	250	0
751	C	251	0
752	C	252	0
753	C	253	0
754	C	254	0
755	C	255	0
756	C	256	0
757	C	257	0
758	C	258	0
759	C	259	0
760	C	260	0
761	C	261	0
762	C	262	0
763	C	263	0
764	C	264	0
765	C	265	0
766	C	266	0
767	C	267	0
768	C	268	0
769	C	269	0
770	C	270	0
771	C	271	0
772	C	272	0
773	C	273	0
774	C	274	0
775	C	275	0
776	C	276	0
777	C	277	0
778	C	278	0
779	C	279	0
780	C	280	0
781	C	281	0
782	C	282	0
783	C	283	0
784	C	284	0
785	C	285	0
786	C	286	0
787	C	287	0
788	C	288	0
789	C	289	0
790	C	290	0
791	C	291	0
792	C	292	0
793	C	293	0
794	C	294	0
795	C	295	0
796	C	296	0
797	C	297	0
798	C	298	0
799	C	299	0
800	C	300	0
801	C	301	0
802	C	302	0
803	C	303	0
804	C	304	0
805	C	305	0
806	C	306	0
807	C	307	0
808	C	308	0
809	C	309	0
810	C	310	0
811	C	311	0
812	C	312	0
813	C	313	0
814	C	314	0
815	C	315	0
816	C	316	0
817	C	317	0
818	C	318	0
819	C	319	0
820	C	320	0
821	C	321	0
822	C	322	0
823	C	323	0
824	C	324	0
825	C	325	0
826	C	326	0
827	C	327	0
828	C	328	0
829	C	329	0
830	C	330	0
831	C	331	0
832	C	332	0
833	C	333	0
834	C	334	0
835	C	335	0
836	C	336	0
837	C	337	0
838	C	338	0
839	C	339	0
840	C	340	0
841	C	341	0
842	C	342	0
843	C	343	0
844	C	344	0
845	C	345	0
846	C	346	0
847	C	347	0
848	C	348	0
849	C	349	0
850	C	350	0
851	C	351	0
852	C	352	0
853	C	353	0
854	C	354	0
855	C	355	0
856	C	356	0
857	C	357	0
858	C	358	0
859	C	359	0
860	C	360	0
861	C	361	0
862	C	362	0
863	C	363	0
864	C	364	0
865	C	365	0
866	C	366	0
867	C	367	0
868	C	368	0
869	C	369	0
870	C	370	0
871	C	371	0
872	C	372	0
873	C	373	0
874	C	374	0
875	C	375	0
876	C	376	0
877	C	377	0
878	C	378	0
879	C	379	0
880	C	380	0
881	C	381	0
882	C	382	0
883	C	383	0
884	C	384	0
885	C	385	0
886	C	386	0
887	C	387	0
888	C	388	0
889	C	389	0
890	C	390	0
891	C	391	0
892	C	392	0
893	C	393	0
894	C	394	0
895	C	395	0
896	C	396	0
897	C	397	0
898	C	398	0
899	C	399	0
900	C	400	0
901	C	401	0
902	C	402	0
903	C	403	0
904	C	404	0
905	C	405	0
906	C	406	0
907	C	407	0
908	C	408	0
909	C	409	0
910	C	410	0
911	C	411	0
912	C	412	0
913	C	413	0
914	C	414	0
915	C	415	0
916	C	416	0
917	C	417	0
918	C	418	0
919	C	419	0
920	C	420	0
921	C	421	0
922	C	422	0
923	C	423	0
924	C	424	0
925	C	425	0
926	C	426	0
927	C	427	0
928	C	428	0
929	C	429	0
930	C	430	0
931	C	431	0
932	C	432	0
933	C	433	0
934	C	434	0
935	C	435	0
936	C	436	0
937	C	437	0
938	C	438	0
939	C	439	0
940	C	440	0
941	C	441	0
942	C	442	0
943	C	443	0
944	C	444	0
945	C	445	0
946	C	446	0
947	C	447	0
948	C	448	0
949	C	449	0
950	C	450	0
951	C	451	0
952	C	452	0
953	C	453	0
954	C	454	0
955	C	455	0
956	C	456	0
957	C	457	0
958	C	458	0
959	C	459	0
960	C	460	0
961	C	461	0
962	C	462	0
963	C	463	0
964	C	464	0
965	C	465	0
966	C	466	0
967	C	467	0
968	C	468	0
969	C	469	0
970	C	470	0
971	C	471	0
972	C	472	0
973	C	473	0
974	C	474	0
975	C	475	0
976	C	476	0
977	C	477	0
978	C	478	0
979	C	479	0
980	C	480	0
981	C	481	0
982	C	482	0
983	C	483	0
984	C	484	0
985	C	485	0
986	C	486	0
987	C	487	0
988	C	488	0
989	C	489	0
990	C	490	0
991	C	491	0
992	C	492	0
993	C	493	0
994	C	494	0
995	C	495	0
996	C	496	0
997	C	497	0
998	C	498	0
999	C	499	0
1000	C	500	0
