package OpenILS::WWW::EGCatLoader;
use strict; use warnings;
use Apache2::Const -compile => qw(OK DECLINED FORBIDDEN HTTP_INTERNAL_SERVER_ERROR REDIRECT HTTP_BAD_REQUEST);
use OpenSRF::Utils::Logger qw/$logger/;
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use OpenILS::Utils::Fieldmapper;
use OpenILS::Application::AppUtils;
my $U = 'OpenILS::Application::AppUtils';


# context additions: 
#   user : au object, fleshed
sub load_myopac {
    my $self = shift;
    $self->ctx->{page} = 'myopac';

    $self->ctx->{user} = $self->editor->retrieve_actor_user([
        $self->ctx->{user}->id,
        {
            flesh => 1,
            flesh_fields => {
                au => ['card']
                # ...
            }
        }
    ]);

    return Apache2::Const::OK;
}


sub fetch_user_holds {
    my $self = shift;
    my $hold_ids = shift;
    my $ids_only = shift;
    my $flesh = shift;
    my $limit = shift;
    my $offset = shift;

    my $e = $self->editor;

    my $circ = OpenSRF::AppSession->create('open-ils.circ');

    if(!$hold_ids) {

        $hold_ids = $circ->request(
            'open-ils.circ.holds.id_list.retrieve.authoritative', 
            $e->authtoken, 
            $e->requestor->id
        )->gather(1);
    
        $hold_ids = [ grep { defined $_ } @$hold_ids[$offset..($offset + $limit - 1)] ] if $limit or $offset;
    }


    return $hold_ids if $ids_only or @$hold_ids == 0;

    my $args = {
        suppress_notices => 1,
        suppress_transits => 1,
        suppress_mvr => 1,
        suppress_patron_details => 1,
        include_bre => $flesh ? 1 : 0
    };

    # ----------------------------------------------------------------
    # Collect holds in batches of $batch_size for faster retrieval

    my $batch_size = 8;
    my $batch_idx = 0;
    my $mk_req_batch = sub {
        my @ses;
        my $top_idx = $batch_idx + $batch_size;
        while($batch_idx < $top_idx) {
            my $hold_id = $hold_ids->[$batch_idx++];
            last unless $hold_id;
            my $ses = OpenSRF::AppSession->create('open-ils.circ');
            my $req = $ses->request(
                'open-ils.circ.hold.details.retrieve', 
                $e->authtoken, $hold_id, $args);
            push(@ses, {ses => $ses, req => $req});
        }
        return @ses;
    };

    my $first = 1;
    my(@collected, @holds, @ses);

    while(1) {
        @ses = $mk_req_batch->() if $first;
        last if $first and not @ses;

        if(@collected) {
            while(my $blob = pop(@collected)) {
                $blob->{marc_xml} = XML::LibXML->new->parse_string($blob->{hold}->{bre}->marc) if $flesh;
                push(@holds, $blob);
            }
        }

        for my $req_data (@ses) {
            push(@collected, {hold => $req_data->{req}->gather(1)});
            $req_data->{ses}->kill_me;
        }

        @ses = $mk_req_batch->();
        last unless @collected or @ses;
        $first = 0;
    }

    # put the holds back into the original server sort order
    my @sorted;
    for my $id (@$hold_ids) {
        push @sorted, grep { $_->{hold}->{hold}->id == $id } @holds;
    }

    return \@sorted;
}

sub handle_hold_update {
    my $self = shift;
    my $action = shift;
    my $e = $self->editor;


    my @hold_ids = $self->cgi->param('hold_id'); # for non-_all actions
    @hold_ids = @{$self->fetch_user_holds(undef, 1)} if $action =~ /_all/;

    my $circ = OpenSRF::AppSession->create('open-ils.circ');

    if($action =~ /cancel/) {

        for my $hold_id (@hold_ids) {
            my $resp = $circ->request(
                'open-ils.circ.hold.cancel', $e->authtoken, $hold_id, 6 )->gather(1); # 6 == patron-cancelled-via-opac
        }

    } else {
        
        my $vlist = [];
        for my $hold_id (@hold_ids) {
            my $vals = {id => $hold_id};

            if($action =~ /activate/) {
                $vals->{frozen} = 'f';
                $vals->{thaw_date} = undef;

            } elsif($action =~ /suspend/) {
                $vals->{frozen} = 't';
                # $vals->{thaw_date} = TODO;
            }
            push(@$vlist, $vals);
        }

        $circ->request('open-ils.circ.hold.update.batch.atomic', $e->authtoken, undef, $vlist)->gather(1);
    }

    $circ->kill_me;
    return undef;
}

sub load_myopac_holds {
    my $self = shift;
    my $e = $self->editor;
    my $ctx = $self->ctx;
    

    my $limit = $self->cgi->param('limit') || 0;
    my $offset = $self->cgi->param('offset') || 0;
    my $action = $self->cgi->param('action') || '';

    $self->handle_hold_update($action) if $action;

    $ctx->{holds} = $self->fetch_user_holds(undef, 0, 1, $limit, $offset);

    return Apache2::Const::OK;
}

sub load_place_hold {
    my $self = shift;
    my $ctx = $self->ctx;
    my $e = $self->editor;
    my $cgi = $self->cgi;
    $self->ctx->{page} = 'place_hold';

    $ctx->{hold_target} = $cgi->param('hold_target');
    $ctx->{hold_type} = $cgi->param('hold_type');
    $ctx->{default_pickup_lib} = $e->requestor->home_ou; # XXX staff

    if($ctx->{hold_type} eq 'T') {
        $ctx->{record} = $e->retrieve_biblio_record_entry($ctx->{hold_target});
    }
    # ...

    $ctx->{marc_xml} = XML::LibXML->new->parse_string($ctx->{record}->marc);

    if(my $pickup_lib = $cgi->param('pickup_lib')) {

        my $args = {
            patronid => $e->requestor->id,
            titleid => $ctx->{hold_target}, # XXX
            pickup_lib => $pickup_lib,
            depth => 0, # XXX
        };

        my $allowed = $U->simplereq(
            'open-ils.circ',
            'open-ils.circ.title_hold.is_possible',
            $e->authtoken, $args
        );

        if($allowed->{success} == 1) {
            my $hold = Fieldmapper::action::hold_request->new;

            $hold->pickup_lib($pickup_lib);
            $hold->requestor($e->requestor->id);
            $hold->usr($e->requestor->id); # XXX staff
            $hold->target($ctx->{hold_target});
            $hold->hold_type($ctx->{hold_type});
            # frozen, expired, etc..

            my $stat = $U->simplereq(
                'open-ils.circ',
                'open-ils.circ.holds.create',
                $e->authtoken, $hold
            );

            if($stat and $stat > 0) {
                # if successful, return the user to the requesting page
                $self->apache->log->info("Redirecting back to " . $cgi->param('redirect_to'));
                $self->apache->print($cgi->redirect(-url => $cgi->param('redirect_to')));
                return Apache2::Const::REDIRECT;

            } else {
                $ctx->{hold_failed} = 1;
            }
        } else { # hold *check* failed
            $ctx->{hold_failed} = 1; # XXX process the events, etc
            $ctx->{hold_failed_event} = $allowed->{last_event};
        }

        # hold permit failed
        $logger->info('hold permit result ' . OpenSRF::Utils::JSON->perl2JSON($allowed));
    }

    return Apache2::Const::OK;
}


sub fetch_user_circs {
    my $self = shift;
    my $flesh = shift; # flesh bib data, etc.
    my $circ_ids = shift;
    my $limit = shift;
    my $offset = shift;

    my $e = $self->editor;

    my @circ_ids;

    if($circ_ids) {
        @circ_ids = @$circ_ids;

    } else {

        my $circ_data = $U->simplereq(
            'open-ils.actor', 
            'open-ils.actor.user.checked_out',
            $e->authtoken, 
            $e->requestor->id
        );

        @circ_ids =  ( @{$circ_data->{overdue}}, @{$circ_data->{out}} );

        if($limit or $offset) {
            @circ_ids = grep { defined $_ } @circ_ids[0..($offset + $limit - 1)];
        }
    }

    return [] unless @circ_ids;

    my $cstore = OpenSRF::AppSession->create('open-ils.cstore');

    my $qflesh = {
        flesh => 3,
        flesh_fields => {
            circ => ['target_copy'],
            acp => ['call_number'],
            acn => ['record']
        }
    };

    $e->xact_begin;
    my $circs = $e->search_action_circulation(
        [{id => \@circ_ids}, ($flesh) ? $qflesh : {}], {substream => 1});

    my @circs;
    for my $circ (@$circs) {
        push(@circs, {
            circ => $circ, 
            marc_xml => ($flesh and $circ->target_copy->call_number->id != -1) ? 
                XML::LibXML->new->parse_string($circ->target_copy->call_number->record->marc) : 
                undef  # pre-cat copy, use the dummy title/author instead
        });
    }
    $e->xact_rollback;

    # make sure the final list is in the correct order
    my @sorted_circs;
    for my $id (@circ_ids) {
        push(
            @sorted_circs,
            (grep { $_->{circ}->id == $id } @circs)
        );
    }

    return \@sorted_circs;
}


sub handle_circ_renew {
    my $self = shift;
    my $action = shift;
    my $ctx = $self->ctx;

    my @renew_ids = $self->cgi->param('circ');

    my $circs = $self->fetch_user_circs(0, ($action eq 'renew') ? [@renew_ids] : undef);

    # TODO: fire off renewal calls in batches to speed things up
    my @responses;
    for my $circ (@$circs) {

        my $evt = $U->simplereq(
            'open-ils.circ', 
            'open-ils.circ.renew',
            $self->editor->authtoken,
            {
                patron_id => $self->editor->requestor->id,
                copy_id => $circ->{circ}->target_copy,
                opac_renewal => 1
            }
        );

        # TODO return these, then insert them into the circ data 
        # blob that is shoved into the template for each circ
        # so the template won't have to match them
        push(@responses, {copy => $circ->{circ}->target_copy, evt => $evt});
    }

    return @responses;
}


sub load_myopac_circs {
    my $self = shift;
    my $e = $self->editor;
    my $ctx = $self->ctx;

    $ctx->{circs} = [];
    my $limit = $self->cgi->param('limit') || 0; # 0 == unlimited
    my $offset = $self->cgi->param('offset') || 0;
    my $action = $self->cgi->param('action') || '';

    # perform the renewal first if necessary
    my @results = $self->handle_circ_renew($action) if $action =~ /renew/;

    $ctx->{circs} = $self->fetch_user_circs(1, undef, $limit, $offset);

    my $success_renewals = 0;
    my $failed_renewals = 0;
    for my $data (@{$ctx->{circs}}) {
        my ($resp) = grep { $_->{copy} == $data->{circ}->target_copy->id } @results;

        if($resp) {
            my $evt = ref($resp->{evt}) eq 'ARRAY' ? $resp->{evt}->[0] : $resp->{evt};
            $data->{renewal_response} = $evt;
            $success_renewals++ if $evt->{textcode} eq 'SUCCESS';
            $failed_renewals++ if $evt->{textcode} ne 'SUCCESS';
        }
    }

    $ctx->{success_renewals} = $success_renewals;
    $ctx->{failed_renewals} = $failed_renewals;

    return Apache2::Const::OK;
}

sub load_myopac_fines {
    my $self = shift;
    my $e = $self->editor;
    my $ctx = $self->ctx;
    $ctx->{"fines"} = {
        "circulation" => [],
        "grocery" => [],
        "total_paid" => 0,
        "total_owed" => 0,
        "balance_owed" => 0
    };

    my $limit = $self->cgi->param('limit') || 0;
    my $offset = $self->cgi->param('offset') || 0;

    my $cstore = OpenSRF::AppSession->create('open-ils.cstore');

    # TODO: This should really be a ML call, but the existing calls 
    # return an excessive amount of data and don't offer streaming

    my %paging = ($limit or $offset) ? (limit => $limit, offset => $offset) : ();

    my $req = $cstore->request(
        'open-ils.cstore.direct.money.open_billable_transaction_summary.search',
        {
            usr => $e->requestor->id,
            balance_owed => {'!=' => 0}
        },
        {
            flesh => 4,
            flesh_fields => {
                mobts => ['circulation', 'grocery'],
                mg => ['billings'],
                mb => ['btype'],
                circ => ['target_copy'],
                acp => ['call_number'],
                acn => ['record']
            },
            order_by => { mobts => 'xact_start' },
            %paging
        }
    );

    while(my $resp = $req->recv) {
        my $mobts = $resp->content;
        my $circ = $mobts->circulation;

        my $last_billing;
        if($mobts->grocery) {
            my @billings = sort { $a->billing_ts cmp $b->billing_ts } @{$mobts->grocery->billings};
            $last_billing = pop(@billings);
        }

        # XXX TODO switch to some money-safe non-fp library for math
        $ctx->{"fines"}->{$_} += $mobts->$_ for (
            qw/total_paid total_owed balance_owed/
        );

        push(
            @{$ctx->{"fines"}->{$mobts->grocery ? "grocery" : "circulation"}},
            {
                xact => $mobts,
                last_grocery_billing => $last_billing,
                marc_xml => ($mobts->xact_type ne 'circulation' or $circ->target_copy->call_number->id == -1) ?
                    undef :
                    XML::LibXML->new->parse_string($circ->target_copy->call_number->record->marc),
            } 
        );
    }

     return Apache2::Const::OK;
}       

sub load_myopac_update_email {
    my $self = shift;
    my $e = $self->editor;
    my $ctx = $self->ctx;
    my $email = $self->cgi->param('email') || '';

    unless($email =~ /.+\@.+\..+/) { # TODO better regex?
        $ctx->{invalid_email} = $email;
        return Apache2::Const::OK;
    }

    my $stat = $U->simplereq(
        'open-ils.actor', 
        'open-ils.actor.user.email.update', 
        $e->authtoken, $email);

    my $url = $self->apache->unparsed_uri;
    $url =~ s/update_email/main/;
    $self->apache->print($self->cgi->redirect(-url => $url));

    return Apache2::Const::REDIRECT;
}

sub load_myopac_bookbags {
    my $self = shift;
    my $e = $self->editor;
    my $ctx = $self->ctx;
    my $limit = $self->cgi->param('limit') || 0;
    my $offset = $self->cgi->param('offset') || 0;

    my $args = {order_by => {cbreb => 'name'}};
    $args->{limit} = $limit if $limit;
    $args->{offset} = $limit if $limit;

    $ctx->{bookbags} = $e->search_container_biblio_record_entry_bucket([
        {owner => $self->editor->requestor->id, btype => 'bookbag'},
        $args
    ]);

    return Apache2::Const::OK;
}


1
