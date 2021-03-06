package CGI::Uploader::Source;
use strict;
use warnings;
require Carp;
use Squirrel;

our $VERSION = '2.90_03';

has temp_dir      => (is => 'rw' , required => 0 , predicate => 'has_temp_dir'      , isa => 'Str');
has temp_filename => (is => 'rw' , required => 0 , predicate => 'has_temp_filename' , isa => 'Str');
has mime_type     => (is => 'rw' , required => 0 , predicate => 'has_mime_type'     , isa => 'Str' , default => '');
has field_value   => (is => 'rw' , required => 0 , predicate => 'has_field_value'   , isa => 'Str');

# -----------------------------------------------

sub upload         { Carp::croak('Method "upload" must be implemented by a subclass') }
# sub temp_filename   { Carp::croak('Method "temp_filename" not implemented by subclass') } 
# sub mime_type      { Carp::croak('Method "mime_type" not implemented by subclass') }  
# sub field_value    { Carp::croak('Method "field_value" not implemented by subclass') }   

# -----------------------------------------------

1;

__END__

=head1 NAME

CGI::Uploader::Source - Base class for sources

=head1 SYNOPSIS

To create a new source, such as a new kind of query object: 

  package CGI::Uploader::Source::MySrc;
  use base 'CGI::Uploader::Source';
  
  sub upload {
    my $self = shift;
    my $field_name = shift; 

    # .... upload action here
    $self->temp_filename('/temp/foo.txt');
    $self->mime_type('text/plain');
    $self->field_value('/home/mark/foo.txt');
    return 1;
  }

The base class is built with L<Mouse>, so you have L<Moose>-like features to
extend it.

To use the source in your upload spec:

 upload_src => CGI::Uploader::Source::MySrc->new(); 

=head1 DESCRIPTION

L<CGI::Uploader::Source> is a base class for upload sources used by L<CGI::Uploader>.

=head1 METHODS

=head2 C<upload>

See the Synopsis. 

Given the name of a file upload field, upload the file and store its name (on the server) in
the C<temp_filename> attribute. If a MIME type was sent, store that in the
C<mime_type> attribute. Also, store the field's value (client file name) in the C<field_value>
attribute if it is available.

=head1 ATTRIBUTES

=head2 temp_filename()

  $src->temp_filename('/temp/foo.txt');
  $filename = $src->temp_filename();

The temporary filename where the result of the upload is stored. Usually set by
calling the 'upload()' method. 

=head2 mime_type()

  $src->mime_type('text/plain');
  $mime = $src->mime_type();

The MIME type sent by the user-agent. Usually set by
calling the 'upload()' method. 

=head2 field_value()

  $src->field_value('/home/mark/foo.txt');
  $value = $src->field_value();

The value of the file upload field.  Usually set by calling the 'upload()'
method. 

=head1 AUTHOR

Mark Stosberg,  C<< mark@summersault.com >>.

=head1 COPYRIGHT

Copyright (C) 2008, Mark Stosberg

This program is free software, you can redistribute it and/or modify it under
the same terms as Perl 5.10.

=cut

