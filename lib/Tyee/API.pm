package Tyee::API;

use warnings;
use strict;

use Data::Dumper;
use ElasticSearch;

use Tyee::Config;
use Tyee::API::Story;

=head1 NAME

Tyee::API - Interface to add/remove documents from the Tyee API

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

my $e = ElasticSearch->new(
    servers   => $config->{'servers'},    # single server
    transport => $config->{'transport'} || 'http',  # default 'http'
    #trace_calls => '/path/to/elastic_search_log',
    timeout => $config->{'timeout'} || 30,
);

#===  FUNCTION  ================================================================
#         NAME:  new
#      PURPOSE:  To return the ES object 
#   PARAMETERS:  none
#      RETURNS:  The object, or an error message
#===============================================================================
sub new {
    my $self  = shift;
    return \$e; 
}

=head1 SYNOPSIS

Add or remove documents from the Tyee API

    use Tyee::API;

    my $result = Tyee::API->create( $type, @object(s) );
    my $result = Tyee::API->delete( $type, @id(s) ); 
    my $doc    = Tyee::API->retreive( $type, $id ); 

=head1 SUBROUTINES/METHODS

=head2 create 

Create and update are the same.
Create expects a type (story, contributor, etc.)
Create expects an array of properly contrstucted objects.
The array may contain only one object for simple insertions.

=cut

sub create {
    my ( $self, $type, $documents ) = @_;
    my $result = _index_documents( $type, $documents ); # Arrayref of results
    return $result;
}    # ----------  end of subroutine create  ----------

=head2 delete

Same as create, only it deletes.

=cut 

sub delete {
    my ( $self, $type, $documents ) = @_;
    my $result = _delete_documents( $type, $documents ); # Arrayref of results
    return $result;
}    # ----------  end of subroutine delete  ----------



=head2 retreive

TODO Needs to be implemented

=cut

#---------------------------------------------------------------------------
#  Helper subroutines
#---------------------------------------------------------------------------

#===  FUNCTION  ================================================================
#         NAME:  _index_documents
#      PURPOSE:
#   PARAMETERS:  Expects and array of story objects from Bricolage
#      RETURNS:  Returns an arrayref of response objects from Elastic Search
#===============================================================================
sub _index_documents {
    my ( $type, $documents ) = @_;
    my @results;
    my $builder = 'Tyee::API::' . $type;
    for my $document ( @$documents ) {
        my $document_to_index = $builder->new( $document );
        my $result            = _index_document( $type, $document_to_index );
        push @results, $result;
    }
    return \@results; # Return the arrayref of result objects to sub new {}
}    # ----------  end of subroutine index_stories  ----------

#===  FUNCTION  ================================================================
#         NAME:  _index_document
#   PARAMETERS:  Expects a Bricolage story object, Perl data structure, and ES
#      RETURNS:  The response from Elastic Search
#===============================================================================
sub _index_document {
    my $type     = shift;
    my $document = shift;
    my $result   = $e->index( 
        index => $config->{'index'},
        type  => lc( $type ),
        id    => $document->{'uuid'},
        data  => {%$document},
    );
    return $result; # Return the result object to _index_documents
}    # ----------  end of subroutine index_story  ----------

#===  FUNCTION  ================================================================
#         NAME:  _delete_documents
#      PURPOSE:
#   PARAMETERS:  Expects and array of story objects from Bricolage
#      RETURNS:  Returns an arrayref of response objects from Elastic Search
#===============================================================================
sub _delete_documents {
    my ( $type, $documents ) = @_;
    my @results;
    my $builder = 'Tyee::API::' . $type;
    for my $document ( @$documents ) {
        my $document_to_delete = $builder->new( $document );
        my $result            = _delete_document( $type, $document_to_delete );
        push @results, $result;
    }
    my $refresh = $e->refresh_index( index => $config->{'index'} );
    push @results, $refresh;
    return \@results; # Return the arrayref of result objects to sub new {}
}    # ----------  end of subroutine index_stories  ----------

#===  FUNCTION  ================================================================
#         NAME:  _delete_document
#   PARAMETERS:  Expects a Bricolage story object, Perl data structure, and ES
#      RETURNS:  The response from Elastic Search
#===============================================================================
sub _delete_document {
    my $type     = shift;
    my $document = shift;
    my $result   = $e->delete( 
        index => $config->{'index'},
        type  => lc( $type ),
        id    => $document->{'uuid'},
    );
    return $result; # Return the result object to _index_documents
}    # ----------  end of subroutine index_story  ----------


