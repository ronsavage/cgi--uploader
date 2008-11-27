package CGI::Up;

use strict;
use warnings;

use File::Basename;
use File::Copy; # For copy.
use File::Path;
use File::Spec;
use File::Temp 'tempfile';

use HTTP::BrowserDetect;

use Image::Size;

use MIME::Types;

use Params::Validate ':all';

use Squirrel;

our $VERSION = '2.90';

# -----------------------------------------------

has dbh      => (is => 'rw', required => 0, predicate => 'has_dbh', isa => 'Any');
has dsn      => (is => 'rw', required => 0, predicate => 'has_dsn', isa => 'Any');
has imager   => (is => 'rw', required => 0, isa => 'Any');
has query    => (is => 'rw', required => 0, predicate => 'has_query', isa => 'Any');
has manager  => (is => 'rw', required => 0, isa => 'Any');
has temp_dir => (is => 'rw', required => 0, predicate => 'has_temp_dir', isa => 'Any');

# -----------------------------------------------

sub BUILD
{
	my($self) = @_;

	# See if the caller specifed a dsn but no dbh.

	if ($self -> has_dsn() && ! $self -> has_dbh() )
	{
		require DBI;

		$self -> dbh(DBI -> connect(@{$self -> dsn()}) );
	}

	# Ensure a query object is available.

	if ($self -> has_query() )
	{
		my($ok)   = 0;
		my(@type) = (qw/Apache::Request Apache2::Request CGI/);

		my($type);

		for $type (@type)
		{
			if ($self -> query() -> isa($type) )
			{
				$ok = 1;

				last;
			}
		}

		if (! $ok)
		{
			confess 'Your query object must be one of these types: ' . join(', ', @type);
		}
	}
	else
	{
		require CGI;

		$self -> query(CGI -> new() );
	}

	# Ensure a temp dir name is available.

	if (! $self -> has_temp_dir() )
	{
		$self -> temp_dir(File::Spec -> tmpdir() );
	}

}	# End of BUILD.

# -----------------------------------------------

sub calculate_dimensions
{
	my($self, $image, $option) = @_;

	if (! ($$option{'width'} || $$option{'height'}) )
	{
		die "transform option requires at least one of width and height";
	}

	my($original_width, $original_height) = $image -> Get('width', 'height');
	my($new_width, $new_height)           = ($$option{'width'}, $$option{'height'});

	if (! $new_width)
	{
		$new_width = sprintf("%.1d", ($original_width * $new_height) / $original_height);
	}

	if (! $new_height)
	{
		$new_height = sprintf("%.1d", ($original_height * $new_width) / $original_width);
	}

	return '%i x %i', $new_width, $new_height;

} # End of calculate_dimensions.

# -----------------------------------------------

sub copy_temp_file
{
	my($self, $temp_file_name, $meta_data, $option) = @_;
	my($path) = $$option{'path'};
	$path     =~ s|^(.+)/$|$1|;

	if ($$option{'file_scheme'} eq 'md5')
	{
		require Digest::MD5;

		import Digest::MD5  qw/md5_hex/;

		my($md5) = md5_hex($$meta_data{'id'});
		$md5     =~ s|^(.)(.)(.).*|$1/$2/$3|;
		$path    = File::Spec -> catdir($path, $md5);
	}

	if (! -e $path)
	{
		File::Path::mkpath($path);
	}

	my($extension)                  = $$meta_data{'extension'};
	$extension                      = $extension ? ".$extension" : '';
	$$meta_data{'server_file_name'} = File::Spec -> catdir($path, "$$meta_data{'id'}$extension");

	copy($temp_file_name, $$meta_data{'server_file_name'});

} # End of copy_temp_file.

# -----------------------------------------------

sub default_column_map
{
	my($self) = @_;

	return
	{
	 client_file_name => 'client_file_name',
	 date_stamp       => 'date_stamp',
	 extension        => 'extension',
	 height           => 'height',
	 id               => 'id',
	 mime_type        => 'mime_type',
	 parent_id        => 'parent_id',
	 server_file_name => 'server_file_name',
	 size             => 'size',
	 width            => 'width',
	};

} # End of default_column_map.

# -----------------------------------------------

sub default_dbh
{
	my($self, $dsn) = @_;

	if (! $self -> has_dbh() )
	{
		# The called checked that at least one of dbh and dsn was specified.
		# So, we don't need to test for dsn here.

		require DBI;

		$self -> dbh(DBI -> connect(@$dsn) );
	}

} # End of default_dbh.

# -----------------------------------------------

sub delete
{
	my($self, %field)       = @_;
	my($field)              = $self -> validate_delete_options(%field);
	my($id_column)          = $$field{'column_map'}{'id'};
	my($parent_id_column)   = $$field{'column_map'}{'parent_id'};
	my($table_name)         = $$field{'table_name'};
	my($server_file_column) = $$field{'column_map'}{'server_file_name'};

	# Ensure a dbh or dsn was specified.

	if (! ($field{'dbh'} || $field{'dsn'}) )
	{
		confess "You must provide at least one of dbh and dsn for 'delete'";
	}

	# Use either the caller's dbh or fabricate one.

	$self -> default_dbh($field{'dsn'});

	# Phase 1: The generated files.

	my($data)   = $self -> dbh() -> selectall_arrayref("select * from $table_name where $parent_id_column = ?", {Slice => {} }, $$field{'id'}) || [];
	my($result) = [];

	my(@file);
	my(@id);
	my($row);

	for $row (@$data)
	{
		if ($$row{$server_file_column})
		{
			push @file, $$row{$server_file_column};
			push @id,   $$row{$id_column};
		}
	}

	my($i);

	for $i (0 .. $#file)
	{
		unlink $file[$i];

		push @$result,
		{
			id        => $id[$i],
			file_name => $file[$i],
		};
	}


	# Phase 2: The generated table rows.

	$self -> dbh() -> do("delete from $table_name where $id_column = $_") for @id;

	# Phase 3: The uploaded file.

	$data = $self -> dbh() -> selectrow_hashref("select * from $table_name where $id_column = ?", {}, $$field{'id'});

	if ($$data{$server_file_column})
	{
		unlink $$data{$server_file_column};

		push @$result,
		{
			id        => $$data{$id_column},
			file_name => $$data{$server_file_column},
		};
	}

	# Phase 4: The uploaded table row.

	$self -> dbh() -> do("delete from $table_name where $id_column = $$field{'id'}");

	return $result;

} # End of delete.

# -----------------------------------------------
# Note: $field_name is not used in the default manager.

sub do_insert
{
	my($self, $field_name, $meta_data, $option) = @_;

	# Use either the caller's dbh or fabricate one.

	$self -> default_dbh($$option{'dsn'});

	my($db_server) = $self -> dbh() -> get_info(17);
	my($sql)       = "insert into $$option{'table_name'}";

	# Ensure, if the caller is using Postgres, and they want the id field populated,
	# that we stuff the next value from the caller's sequence into it.

	if ( ($db_server eq 'PostgreSQL') && $$option{'column_map'}{'id'})
	{
		$$meta_data{'id'} = $self -> dbh() -> selectrow_array("select nextval('$$option{'sequence_name'}')");
	}

	my(@bind);
	my(@column);
	my($key);

	for $key (keys %$meta_data)
	{
		# Skip columns the caller does not want processed.

		if (! $$option{'column_map'}{$key})
		{
			next;
		}

		push @column, $$option{'column_map'}{$key};

		# For SQLite, we must use undef for the id, since DBIx::Admin::CreateTable's
		# method generate_primary_key_sql() returns 'integer primary key auto_increment'
		# for an SQLite primary key, and SQLite demands a NULL be inserted to get the
		# autoincrement part of that to work. See http://www.sqlite.org/faq.html#q1.

		push @bind, ( ($db_server eq 'SQLite') && ($key eq 'id') ) ? undef : $$meta_data{$key};
	}

	$sql     .= '(' . join(', ', @column) . ') values (' . ('?, ' x $#bind) . '?)';
	my($sth) = $self -> dbh() -> prepare($sql);

	$sth -> execute(@bind);

	$$meta_data{'id'} = $self -> dbh() -> last_insert_id(undef, undef, $$option{'table_name'}, undef);

} # End of do_insert.

# -----------------------------------------------

sub do_transform
{
	my($self, $old_file_name, $meta_data, $option) = @_;
	my($temp_fh, $temp_file_name) = tempfile('CGIuploaderXXXXX', UNLINK => 1, DIR => $self -> temp_dir() );

	if (! $$option{'imager'})
	{
		require Image::Magick;

		$$option{'imager'} = Image::Magick -> new();
	}

	if ($$option{'imager'} -> isa('Image::Magick') )
	{
		my($result)     = $$option{'imager'} -> Read($old_file_name);
		my($dimensions) = $self -> calculate_dimensions($$option{'imager'}, $option);
		$result         = $$option{'imager'} -> Resize($dimensions);
		$result         = $$option{'imager'} -> Write($temp_file_name);
	}
	elsif ($$option{'imager'} -> isa('Imager') )
	{
		my($result)     = $$option{'imager'} -> read(file => $old_file_name, type => $$meta_data{'extension'});
		my($new_image)  = $$option{'imager'} -> scale(%{$$option{'options'} });
		my($extension)  = $$meta_data{'extension'};
		$extension      = $extension ? ".$extension" : '';
		$temp_file_name = "$temp_file_name$extension";
		$result         = $new_image -> write(file => $temp_file_name, type => $$meta_data{'extension'});
	}

	$$meta_data{'size'} = (stat $temp_file_name)[7];

	return ($temp_fh, $temp_file_name);

} # End of do_transform.

# -----------------------------------------------

sub do_update
{
	my($self, $field_name, $meta_data, $option) = @_;

	# Skip columns the caller does not want processed.
	# o This is the SQL with the default columns, i.e. the maximum number which are meaningful by default.
	# o my($sql) = "update $$option{'table_name'} set server_file_name = ?, height = ?, width = ? where id = ?";

	my($column, @clause);
	my(@bind);

	for $column (qw/server_file_name height width/)
	{
		if ($$option{'column_map'}{$column})
		{
			push @clause, "$$option{'column_map'}{$column} = ?";
			push @bind, $$meta_data{$column};
		}
	}

	if (@clause)
	{
		my($sql) = "update $$option{'table_name'} set " . join(', ', @clause) .
			" where $$option{'column_map'}{'id'} = ?";

		my($sth) = $self -> dbh() -> prepare($sql);

		$sth -> execute(@bind, $$meta_data{'id'});
	}

} # End of do_update.

# -----------------------------------------------

sub do_upload
{
	my($self, $field_name, $temp_file_name) = @_;
	my($q)         = $self -> query();
	my($file_name) = $q -> param($field_name);

	# Now strip off the volume/path info, if any.

	my($client_os) = $^O;
	my($browser)   = HTTP::BrowserDetect -> new();
	$client_os     = 'MSWin32' if ($browser -> windows() );
	$client_os     = 'MacOS'   if ($browser -> mac() );
	$client_os     = 'Unix'    if ($browser->macosx() );

	File::Basename::fileparse_set_fstype($client_os);

	$file_name = File::Basename::fileparse($file_name,[]);

	my($fh);
	my($mime_type);

	if ($q -> isa('Apache::Request') || $q -> isa('Apache2::Request') )
	{
		my($upload) = $q -> upload($field_name);
		$fh         = $upload -> fh();
		$mime_type  = $upload -> type();
	}
	else # It's a CGI.
	{
		$fh        = $q -> upload($field_name);
		$mime_type = $q -> uploadInfo($fh);

		if ($mime_type)
		{
			$mime_type = $$mime_type{'Content-Type'};
		}

		if (! $fh && $q -> cgi_error() )
		{
			confess $q -> cgi_error();
		}
	}

	if (! $fh)
	{
		confess 'Unable to generate a file handle';
	}

	binmode($fh);
	copy($fh, $temp_file_name) || confess "Unable to create temp file '$temp_file_name': $!";

	# Determine the file extension, if any.

	my($mime_types) = MIME::Types -> new();
	my($type)       = $mime_types -> type($mime_type);
	my(@extension)  = $type ? $type -> extensions() : ();
	my($client_ext) = ($file_name =~ m/\.([\w\d]*)?$/);
	$client_ext     = '' if (! $client_ext);
	my($server_ext) = '';

	if ($extension[0])
	{
		# If the client extension is one recognized by MIME::Type, use it.

		if (defined($client_ext) && (grep {/^$client_ext$/} @extension) )
		{
			$server_ext = $client_ext;
		}
	}
	else
	{
		# If is a provided extension but no MIME::Type extension, use that.

		$server_ext = $client_ext;
	}

	return
	{
		client_file_name => $file_name,
		date_stamp       => 'now()',
		extension        => $server_ext,
		height           => 0,
		id               => 0,
		mime_type        => $mime_type || '',
		parent_id        => 0,
		server_file_name => '',
		size             => (stat $temp_file_name)[7],
		width            => 0,
	};

} # End of do_upload.

# -----------------------------------------------

sub generate
{
	my($self, %field) = @_;
	my($field)        = $self -> validate_generate_options(%field);

	# Ensure a dbh or dsn was specified.

	if (! $self -> has_dbh() && ! ($$field{'dbh'} || $$field{'dsn'}) )
	{
		confess "You must provide at least one of dbh and dsn for 'generate'";
	}

	# Use either the caller's dbh or fabricate one.

	$self -> default_dbh($$field{'dsn'});

	my(@id)         = keys %{$$field{'records'} };
	my($sql)        = "select * from $$field{'table_name'} where $$field{'column_map'}{'id'} in (" . ('?, ') x $#id . '?)';
	my($data)      = $self -> dbh() -> selectall_hashref($sql, 'id', {}, @id);
	my($map)       = $self -> default_column_map();
	my($meta_data) = {};
	my($option)    = {};
	my($column)    = {};

	my($id);
	my($key);
	my($record);
	my($temp_file_name);

	for $id (keys %$data)
	{
		for $key (keys %$map)
		{
			$$column{$key} = $$data{$id}{$$field{'column_map'}{$key} };
		}

		for $record (@{$$field{'records'}{$id} })
		{
			$$option{'imager'}        = $$record{'imager'} || $self -> imager();
			$$option{'options'}       = $$record{'options'};
			$$meta_data{'extension'}  = $$column{'extension'};
			$temp_file_name           = $self -> do_transform($$column{'server_file_name'}, $meta_data, $option);

			$self -> copy_temp_file($temp_file_name, $meta_data, $option);

			$$option{'column_map'}    = $$field{'column_map'};
			$$option{'file_scheme'}   = $$field{'file_scheme'};
			$$option{'meta_data'}     = $column;
			$$option{'path'}          = $$field{'path'};
			$$option{'sequence_name'} = $$record{'sequence_name'};
			$$option{'table_name'}    = $$record{'table_name'};

			$$option{'manager'} -> do_insert($$meta_data{'server_file_name'}, $meta_data, $option);

			print "$id => $$column{'client_file_name'} => $$meta_data{'server_file_name'}. \n";

			File::Temp::cleanup();
		}
	}

	return {map{($_ => [2, 3])} @id};

} # End of generate.

# -----------------------------------------------

sub get_size
{
	my($self, $meta_data) = @_;
	my(@size)             = Image::Size::imgsize($$meta_data{'server_file_name'});
	$$meta_data{'height'} = $size[0] ? $size[0] : 0;
	$$meta_data{'width'}  = $size[0] ? $size[1] : 0;

} # End of get_size.

# -----------------------------------------------

sub upload
{
	my($self, %field) = @_;

	# Loop over the CGI form fields.

	my($field_name, $field_option);
	my($id);
	my($meta_data, @meta_data);
	my($store, $store_option);

	for $field_name (sort keys %field)
	{
		$field_option = $field{$field_name};

		# Perform the upload for this field.

		my($temp_fh, $temp_file_name) = tempfile('CGIuploaderXXXXX', UNLINK => 1, DIR => $self -> temp_dir() );
		$meta_data                    = $self -> do_upload($field_name, $temp_file_name);
		my($store_count)              = 0;

		# Loop over all store options.

		for $store_option (@$field_option)
		{
			$store_count++;

			# Ensure a dbh or dsn was specified.

			if (! ($$store_option{'dbh'} || $$store_option{'dsn'}) )
			{
				confess "You must provide at least one of dbh and dsn for form field '$field_name'";
			}

			$store_option = $self -> validate_upload_options(%$store_option);

			if ($$store_option{'transform'})
			{
				$temp_file_name = $self -> do_transform($temp_file_name, $meta_data, $$store_option{'transform'});
			}

			$$store_option{'manager'} -> do_insert($field_name, $meta_data, $store_option);
			$self -> copy_temp_file($temp_file_name, $meta_data, $store_option);

			if ($store_count == 1)
			{
				$self -> get_size($meta_data);
				$$store_option{'manager'} -> do_update($field_name, $meta_data, $store_option);
			}

			push @meta_data, {field => $field_name, id => $$meta_data{'id'} };
		}

		File::Temp::cleanup();
	}

	return \@meta_data;

} # End of upload.

# -----------------------------------------------

sub validate_delete_options
{
	my($self)  = shift @_;
	my(%param) = validate
	(
	 @_,
	 {
		 column_map =>
		 {
			 optional => 1,
			 type     => UNDEF | HASHREF,
		 },
		 dbh =>
		 {
			 callbacks =>
			 {
				 postgres => sub
				 {
					 my($result) = 1;

					 # If there is a dbh, is the database Postgres,
					 # and, if so, is the sequence_name provided?

					 if ($$_[0])
					 {
						 my($db_server) = $$_[0] -> get_info(17);

						 $result = ($db_server eq 'PostgreSQL') ? $$_[1]{'sequence_name'} : 1;
					 }

					 return $result;
				 },
			 },
			 optional => 1,
			 type     => UNDEF | SCALAR,
		 },
		 dsn =>
		 {
			 optional => 1,
			 type     => UNDEF | ARRAYREF,
		 },
		 id =>
		 {
			 type => SCALAR,
		 },
		 table_name =>
		 {
			 type => SCALAR,
		 },
	 },
	);

	# Must do this separately, because when undef is passed in,
	# Params::Validate does not honour the default clause :-(.

	$param{'column_map'} ||= $self -> default_column_map();

	return {%param};

} # End of validate_delete_options.

# -----------------------------------------------

sub validate_generate_options
{
	my($self)  = shift @_;
	my(%param) = validate
	(
	 @_,
	 {
		 column_map =>
		 {
			 optional => 1,
			 type     => UNDEF | HASHREF,
		 },
		 dbh =>
		 {
			 optional => 1,
			 type     => UNDEF | SCALAR,
		 },
		 dsn =>
		 {
			 optional => 1,
			 type     => UNDEF | ARRAYREF,
		 },
		 file_scheme =>
		 {
			 optional => 1,
			 type     => UNDEF | SCALAR,
		 },
		 path =>
		 {
			 type => SCALAR,
		 },
		 records =>
		 {
			 type => HASHREF,
		 },
		 table_name =>
		 {
			 type => SCALAR,
		 },
	 },
	);

	# Must do this separately, because when undef is passed in,
	# Params::Validate does not honour the default clause :-(.

	$param{'column_map'}  ||= $self -> default_column_map();
	$param{'file_scheme'} ||= 'simple';

	return {%param};

} # End of validate_generate_options.

# -----------------------------------------------

sub validate_upload_options
{
	my($self)  = shift @_;
	my(%param) = validate
	(
	 @_,
	 {
		 column_map =>
		 {
			 optional => 1,
			 type     => UNDEF | HASHREF,
		 },
		 dbh =>
		 {
			 callbacks =>
			 {
				 postgres => sub
				 {
					 my($result) = 1;

					 # If there is a dbh, is the database Postgres,
					 # and, if so, is the sequence_name provided?

					 if ($$_[0])
					 {
						 my($db_server) = $$_[0] -> get_info(17);

						 $result = ($db_server eq 'PostgreSQL') ? $$_[1]{'sequence_name'} : 1;
					 }

					 return $result;
				 },
			 },
			 optional => 1,
			 type     => UNDEF | SCALAR,
		 },
		 dsn =>
		 {
			 optional => 1,
			 type     => UNDEF | ARRAYREF,
		 },
		 file_scheme =>
		 {
			 optional => 1,
			 type     => UNDEF | SCALAR,
		 },
		 imager =>
		 {
			 optional => 1,
			 type     => UNDEF | SCALAR,
		 },
		 manager =>
		 {
			 optional => 1,
			 type     => UNDEF | SCALAR,
		 },
		 path =>
		 {
			 type => SCALAR,
		 },
		 sequence_name =>
		 {
			 optional => 1,
			 type     => UNDEF | SCALAR,
		 },
		 table_name =>
		 {
			 type => SCALAR,
		 },
		 transform =>
		 {
			 optional => 1,
			 type     => UNDEF | HASHREF,
		 },
	 },
	);

	# Must do these separately, because when undef is passed in,
	# Params::Validate does not honour the default clause :-(.

	$param{'column_map'}  ||= $self -> default_column_map();
	$param{'file_scheme'} ||= 'simple';
	$param{'imager'}      ||= $self -> imager()  || $self;
	$param{'manager'}     ||= $self -> manager() || $self;

	return {%param};

} # End of validate_upload_options.

# -----------------------------------------------

1;

=pod

=head1 NAME

CGI::Uploader - Manage CGI uploads using an SQL database

=head1 Synopsis

	# Create an upload object
	# -----------------------

	my($u) = CGI::Uploader -> new # Mandatory.
	(
		dbh      => $dbh,  # Optional. Or specify in call to upload().
		dsn      => [...], # Optional. Or specify in call to upload().
		imager   => $obj,  # Optional. Or specify in call to upload's transform.
		manager  => $obj,  # Optional. Or specify in call to upload().
		query    => $q,    # Optional.
		temp_dir => $t,    # Optional.
	);

	# Upload N files
	# --------------

	my($meta_data) = $u -> upload # Mandatory.
	(
	form_field_1 => # An arrayref of hashrefs. The keys are CGI form field names.
	[
	{ # First, mandatory, set of options for storing the uploaded file.
	column_map    => {...}, # Optional.
	dbh           => $dbh,  # Optional. But one of dbh or dsn is
	dsn           => [...], # Optional. mandatory if no manager.
	file_scheme   => $s,    # Optional.
	manager       => $obj,  # Optional. If present, all others params are optional.
	sequence_name => $s,    # Optional, but mandatory if Postgres and no manager.
	table_name    => $s,    # Optional if manager, but mandatory if no manager.
	transform     => {...}  # Optional.
	},
	{ # Second, etc, optional sets of options for storing copies of the file.
	},
	],
	form_field_2 => [...], # Another arrayref of hashrefs.
	);

	# Delete N files for each uploaded file
	# -------------------------------------

	my($report) = $u -> delete # Optional.
	(
	column_map => {...}, # Mandatory.
	dbh        => $dbh,  # Optional. But one of dbh or dsn is
	dsn        => [...], # Optional. mandatory.
	id         => $id,   # Mandatory.
	table_name => $s,    # Mandatory.
	);

	# Generate N files from each uploaded file
	# ----------------------------------------

	$u -> generate # Optional.
	(
	form_field_1 => [...], # Mandatory. An arrayref of hashrefs.
	form_field_2 => [...], # Mandatory. Another arrayref of hashrefs.
	);

The simplest option, then, is to use

	CGI::Uploader -> new() -> upload(file_name => [{dbh => $dbh, table_name => 'uploads'}]);

and let C<CGI::Uploader> do all the work.

For Postgres, make that

	CGI::Uploader -> new() -> upload(file_name => [{dbh => $dbh, sequence_name => 'uploads_id_seq', table_name => 'uploads'}]);

=head1 Description

C<CGI::Uploader> is a pure Perl module.

=head1 Warning: V 2 'v' V 3

The API for C<CGI::Uploader> version 3 is not compatible with the API for version 2.

This is because V 3 is a complete rewrite of the code, taking in to account all the things
learned from V 2.

=head1 Constructor and initialization

C<new()> returns a C<CGI::Uploader> object.

This is the class's contructor.

You must pass a hash to C<new()>.

Options:

=over 4

=item dbh => $dbh

This key may be specified globally or in the call to C<upload()>.

See below for an explanation, including how this key interacts with I<dsn>.

This key (dbh) is optional.

=item dsn => $dsn

This key may be specified globally or in the call to C<upload()>.

See below for an explanation, including how this key interacts with I<dbh>.

This key (dsn) is optional.

=item imager => $obj

This key may be specified globally or in the call to C<upload>'s I<transform>.

This object is used to handle the transformation of images.

This key (imager) is optional.

=item manager => $obj

This key may be specified globally or in the call to C<upload()>.

This object is used to handle the transfer of meta-data into the database.

This key (manager) is optional.

=item query => $q

Use this to pass in a query object.

This object is expected to belong to one of these classes:

=over 4

=item Apache::Request

=item Apache2::Request

=item CGI

=back

If not provided, an object of type C<CGI> will be created and used to do the uploading.

If you want to use a different type of object, just ensure it has these CGI-compatible methods:

=over 4

=item cgi_error()

This is only called if something goes wrong.

=item upload()

=item uploadInfo()

=back

I<Warning>: CGI::Simple cannot be supported. See this ticket, which is I<not> resolved:

http://rt.cpan.org/Ticket/Display.html?id=14838

There is a comment in the source code of CGI::Simple about this issue. Search for 14838.

This key (query) is optional.

=item temp_dir => $string

Note the spelling of I<temp_dir>.

If not provided, an object of type C<File::Spec> will be created and its tmpdir() method called.

This key (temp_dir) is optional.

=back

=head1 Transformation 'v' Generation

I<Transform> is an optional component in the call to C<upload()>.

C<Generate()> is a separate method.

This section discusses these 2 processes.

Tranformation:

=over 4

=item You must specify a CGI form field

This means transformation takes exactly 1 input file.

=item The file is uploaded before being transformed

=item The uploaded file is transformed and saved

=item The uploaded file is discarded

=item The transformed file's meta-data goes in the database

This means transformation outputs exactly 1 file.

=back

Generation:

=over 4

=item There is no upload associated with generation

=item The file used as a basis for generation must be in the database

This means generation takes exactly 1 input file.

So this input file was, presumably, uploaded at some time in the past, and may have been
transformed at that time.

=item You specify how to generate a new file based on an old file

That is, you specify a set of options which control the generation of 1 new file.

=item You specify N >= 1 sets of such options

This means generation outputs N >= 1 new files.

=item The old file stays in the database

=item All the generated files' meta-data go in the database.

=back

A typical use of generation would be to produce thumbnails of large images.

=head1 Method: delete(%hash)

Note: Methods are listed here in alphabetical order. So C<delete()> comes before C<upload()>.
Nevertheless, the most detailed explanations of options are under C<upload()>, with only brief notes
here under C<delete()>.

You must pass a hash to C<delete()>.

I<delete(%hash)> deletes everything associated with a given database table id.

The keys of this hash are reserved words, and the values are your options.

=over 4

=item column_map => {...}

See below for a discussion of I<column_map>.

Note: If your column map does not contain the I<server_file_name> key, C<delete(%hash)> will do nothing
because it won't be able to find any file names to delete.

The key (column_map) is optional.

=item dbh => $dbh

This key may be specified globally or in the call to C<delete()>.

See below for an explanation, including how this key interacts with I<dsn>.

This key (dbh) is optional.

=item dsn => $dsn

This key may be specified globally or in the call to C<delete()>.

See below for an explanation, including how this key interacts with I<dbh>.

This key (dsn) is optional.

=item id => $id

This is the (primary) key of the database table which will be processed.

To specify a column name other than I<id>, use the I<column_map> option.

This key (id) is mandatory.

=item table_name => $string

This is the name of the database table.

This key (table_name) is mandatory.

=back

There is no I<manager> key because there is no point in you passing all these options to C<delete(%hash)>
just so this method can pass them all back to your manager.

The items deleted are:

=over 4

=item All files generated from the uploaded file

They can be identified because their I<parent_id> column matches $id, and their file names come from the
I<server_file_name> column.

=item The records in the table whose I<parent_id> matches $id

=item The uploaded file

It can be identified becase its I<id> column matches $id, and its file name comes from the
I<server_file_name> column.

=item The record in the table whose I<id> matches $id

=back

C<delete(%hash)> returns an array ref of hashrefs.

Each hashref has 2 keys and 2 values:

=over 4

=item id => $id

$id is the value of the (primary) key column of a deleted file.

One of these $id values will be the $id you passed in to C<delete(%hash)>.

=item file_name => $string

$string is the name of a deleted file.

=back

=head1 Method: generate(%hash)

You must pass a hash to C<upload()>.

The keys to this hash are:

=over 4

=item column_map

The default column_map is documented below, under I<Details>.

This key (column_map) is optional.

=item dbh

I<Dbh> is documented below, under I<Details>.

At least one of I<dbh> and I<dsn> must be provided.

=item dsn

I<Dbh> is documented below, under I<Details>.

At least one of I<dbh> and I<dsn> must be provided.

=item file_scheme => $string

I<file_scheme> is documented below, under I<Details>.

I<File_scheme> defaults to I<string>.

This key (file_scheme) is optional.

=item manager => $obj

I<Manager> is documented below, under I<Details>.

This key (manager) is optional.

=item path => $string

I<Path> is documented below, under I<Details>.

This key (path) is mandatory.

=item records => {...}

I<Records> specifies which (primary) keys in the table are used to find files to process.

These files are input files, and the options in the hashref specify how to use those files
to generate output files.

The keys in the hashref are the keys in the table. E.g.:

	records => {1 => [...], 99 => [...]}

specifies that only records with ids of 1 and 99 are to be processed.

The name of the (primary) key column defaults to I<id>, but you can use I<column_map> to change that.

The name of the input file comes from the I<server_file_name> column of the table. Use I<column_map>
to change that column name.

The arrayrefs are used to specify N >= 1 output files for each input file.

So, each arrayref contains N >= 1 hashrefs, and each hashref specifies how to generate 1 output file. E.g.:

	records => {1 => [{...}, {...}], 99 => [{...}]}

This says use id 1 to generate 2 output files, and use id 99 to generate 1 output file.

The structures of the inner-most hashrefs is exactly the same as the hashrefs pointed to by the
<transform> key, documented at the end of the section on C<upload()>. E.g.:

For an I<imager> object of type C<Image::Magick>:

	records => {1 => [{imager => $obj, width => $w, height => $h}, {...}], 99 => [{...}]}

or, for an I<imager> object of type C<Imager>:

	records => {1 => [{imager => $obj, options => {xpixels => $x, ypixels => $y}, {...}], 99 => [{...}]}

C<CGI::Uploader> takes care of the I<meta-data> for each generated file.

This key (records) is mandatory.

=item sequence_name => $string

I<Sequence_name> is documented below, under I<Details>.

This key is mandatory if you are using Postgres, and optional if not.

=item table_name => $string

This key (table_name) is mandatory.

=back

Note: C<generate()> returns an hashref of arrayrefs, where the keys of the hashref are the ids
provided in the I<records> hashref, and the arrayrefs list the ids of the files generated.

You can use this data, e.g., to read the meta-data from the database and populate form fields to
inform the user of the results of the generation process.

=head1 Method: upload(%hash)

You must pass a hash to C<upload()>.

The keys of this hash are CGI form field names (where the fields are of type I<file>).

C<CGI::Uploader> cycles thru these keys, using each one in turn to drive a single upload.

Note: C<upload()> returns an arrayref of hashrefs, one hashref for each uploaded file stored.

The hashrefs returned are not the I<meta-data> associated with each uploaded file, but more like status reports.

These status reports are explained here, and the I<meta-data> is explained in the next section.

The structure of these status hashrefs is 2 keys and 2 values:

=over 4

=item I<field> => CGI form field name

=item I<id>    => The value of the id column in the database

=back

You can use this data, e.g., to read the meta-data from the database and populate form fields to
inform the user of the results of the upload.

=head1 Meta-data

I<Meta-data> associated with each uploaded file is accumulated while I<upload()> works.

Meta-data is a hashref, with these keys:

=over 4

=item client_file_name

The client_file_name is the name supplied by the web client to C<CGI::Uploader>. It may
I<or may not> have path information prepended, depending on the web client.

=item date_stamp

This value is the string 'now()', until the meta-data is saved in the database.

At that time, the value of the function I<now()> is stored, except for SQLite, which just stores
the string 'now()'.

I<Date_stamp> has an underscore in it in case your database regards datastamp as a reserved word.

=item extension

This is provided by the C<File::Basename> module.

The extension is a string I<without> the leading dot.

If an extension cannot be determined, the value will be '', the empty string.

=item height

This is provided by the I<Image::Size> module, if it recognizes the type of the file.

For non-image files, the value will be 0.

=item id

The id is (presumably) the primary key of your table.

This value is 0 until the meta-data is saved in the database.

In the case of Postgres, it will be populated by the sequence named with the I<sequence_name> key, below.

=item mime_type

This is provided by the I<MIME::Types> module, if it can determine the type.

If not, it is '', the empty string.

=item parent_id

This is populated when a file is generated from the uploaded file. It's value will be the id of
the upload file's record.

For the uploaded file itself, the value will be 0.

=item server_file_name

The server_file_name is the name under which the file is finally stored on the file system
of the web server. It is not the temporary file name used during the upload process.

=item size

This is the size in bytes of the uploaded file.

=item width

This is detrmined by the I<Image::Size> module, if it recognizes the type of the file.

For non-image files, the value will be 0.

=back

=head1 Processing Steps

A mini-synopsis:

	$u -> upload
	(
	file_name_1 =>
	[
	{First set of storage options for this file},
	{Second set of storage options for the same file},
	{...},
	],
	);

=over 4

=item Upload file

C<upload()> calls C<do_upload()> to do the work of uploading the caller's file to a temporary file.

This is done once, whereas the following steps are done once for each hashref of storage options
you specify in the arrayref pointed to by the 'current' CGI form field's name.

C<do_upload()> returns a hashref of meta-data associated with the file.

=item Transform the file

If requested, call C<do_transform()>.

=item Save the meta-data

C<upload()> calls the C<do_insert()> method on the manager object to insert the meta-data into the
database.

The default manager is C<CGI::Uploader> itself.

C<do_insert()> saves the I<last insert id> from that insert in the meta-data hashref.

=item Create the permanent file

C<upload()> calls C<copy_temp_file()> to save the file permanently.

C<copy_temp_file()> saves the permanent file name in the meta-data hashref.

=item Determine the height and width of images

C<upload()> calls the C<get_size()> method to get the image size, which delegates the work to C<Image::Size>.

C<get_size()> saves the image's dimensions in the meta-data hashref.

=item Update the database with the permanent file's name and image size

C<upload()> calls the C<do_update()> method on the manager object to put the permanent file's name
into the database record, along with the height and width.

=back

=head2 Details

Each key in the hash passed in to C<upload()> points to an arrayref of options which specifies how to process the
form field.

Use multiple elements in the arrayref to store multiple sets of meta-data, all based on the same uploaded file.

Each hashref contains 1 .. 5 of the following keys:

=over 4

=item column_map => {...}

This hashref maps column_names used by C<CGI::Uploader> to column names used by your database table.

The default column_map is:

	{
	client_file_name => 'client_file_name',
	date_stamp       => 'date_stamp',
	extension        => 'extension',
	height           => 'height',
	id               => 'id',
	mime_type        => 'mime_type',
	parent_id        => 'parent_id',
	server_file_name => 'server_file_name',
	size             => 'size',
	width            => 'width',
	}

If you supply a different column map, the values on the right-hand side are the ones you change.

Points to note:

=over 4

=item Omitting keys

If you omit any keys from your map, the corresponding meta-data will not be available.

=back

This key (column_map) is optional.

=item dbh => $dbh

This is a database handle for use by the default manager class (which is just C<CGI::Uploader>)
discussed below, under I<manager>.

This key is optional if you use the I<manager> key, since in that case you do anything in your own
storage manager code.

If you do provide the I<dbh> key, it is passed in to your manager just in case you need it.

Also, if you provide I<dbh>, the I<dsn> key, below, is ignored.

If you do not provide the I<dbh> key, the default manager uses the I<dsn> arrayref to create a
dbh via C<DBI>.

=item dsn => [...]

This key is optional if you use the I<manager> key, since in that case you do anything in your own
storage manager code.

If you do provide the I<dsn> key, it is passed in to your manager just in case you need it.

Using the default I<manager>, this key is ignored if you provide a I<dbh> key, but it is mandatory
when you do not provide a I<dbh> key.

The elements in the arrayref are:

=over 4

=item A connection string

E.g.: 'dbi:Pg:dbname=test'

This element is mandatory.

=item A username string

This element is mandatory, even if it's just the empty string.

=item A password string

This element is mandatory, even if it's just the empty string.

=item A connection attributes hashref

This element is optional.

=back

The default manager class calls DBI -> connect(@$dsn) to connect to the database, i.e. in order
to generate a I<dbh>, when you don't provide a I<dbh> key.

=item file_scheme => $string

I<File_scheme> controls how files are stored on the web server's file system.

All files are stored in the directory specified by the I<path> option.

Each file name has the appropriate extension appended (as determined by C<MIME::Types>.

The possible values of I<file_scheme> are:

=over 4

=item md5

The file name is determined like this:

=over 4

=item Digest::MD5

Use the (primary key) I<id> (returned by storing the meta-data in the database) to seed
the Digest::MD5 module.

=item Create 3 subdirectories

Use the first 3 digits of the hex digest of the id to generate 3 levels of sub-directories.

=item Add the name

The file name is the (primary key) I<id>.

=back

=item simple

The file name is the (primary key) I<id>.

I<Simple> is the default.

=back

This key (file_scheme) is optional.

=item manager => $object

This is an instance of your class which will manage the transfer of meta-data to a database table.

In the case you provide the I<manager> key, your object is responsible for saving (or discarding!) the meta-data.

If you provide an object here, C<CGI::Uploader> will call
$object => do_insert($field_name, $meta_data, $store_option).

Parameters are:

=over 4

=item $field_name

I<$field_name> will be the 'current' CGI form field.

Remember, I<upload()> is iterating over all your CGI form field parameters at this point.

=item $meta_data

I<$meta_data> will be a hashref of options generated by the uploading process

See above, under I<column_map>, for the definition of the meta-data. Further details are below,
under I<Meta-data>.

=item $store_option

I<$store_option> will be the 'current' hashref of storage options, one of the arrayref elements
associated with the 'current' form field.

=back

If you do not provide the I<manager> key, C<CGI::Uploader> will do the work itself.

Later, C<CGI::Uploader> will call $object => do_update($field_name, $meta_data, $store_option),
as explained above, under I<Processing Steps>.

This key (manager) is optional.

=item path => $string

This is a path on the web server's file system where a permanent copy of the uploaded file will be saved.

This key (path) is mandatory.

=item sequence_name => $string

This is the name of the sequence used to generate values for the primary key of the table.

You would normally only need this when using Postgres.

This key is optional if you use the I<manager> key, since in that case you can do anything in your own
storage manager code. If you do provide the I<sequence_name> key, it is passed in to your manager
just in case you need it.

This key is mandatory if you use Postgres and do not use the I<manager> key, since without the I<manager> key,
I<sequence_name> must be passed in to the default manager (C<CGI::Uploader>).

=item table_name => $string

This is the name of the table into which to store the meta-data.

This key is optional if you use the I<manager> key, since in that case you can do anything in your own
storage manager code. If you do provide the I<table_name> key, it is passed in to your manager
just in case you need it.

This key is mandatory if you do not use the I<manager> key, since without the I<manager> key,
I<table_name> must be passed in to the default manager (C<CGI::Uploader>).

=item transform => {...}

This key points to a set of options which are used to transform the uploaded file.

As stated above, transformation takes 1 input file, uploads it, transforms it, saves the transformed
file, and discards the uploaded file.

See also C<generate()>, for a completely different way of processing files.

Here are the 2 examples I used in testing, but not at the same time!

	 transform =>
	 {
		 imager => Image::Magick -> new(), # Optional. Default.
		 height => 400,
		 width  => 500,
	 }

	 transform =>
	 {
		 imager  => Imager -> new(),
		 options => {xpixels => 400, ypixels => 500},
	 }

Clearly, I<transform> points to a hashref:

=over 4

=item imager => $obj

The I<imager> key is optional. If omitted, C<CGI::Uploader> creates an object of type C<Image::Magick>,
and uses that.

You can pass in an object whose class is a descendent of C<Image::Magick> or C<Imager>.

They are treated differently, as explained next.

=item height => 'Int', width => 'Int'

If the $obj isa('Image::Magick') you must pass in at least 1 of I<height> and I<width>.

The missing one is calculated from the size of the input image and the given parameter.

Here's what happens:

	if ($$option{'imager'} -> isa('Image::Magick') )
	{
		my($result)     = $$option{'imager'} -> Read($old_file_name);
		my($dimensions) = $self -> calculate_dimensions($$option{'imager'}, $option);
		$result         = $$option{'imager'} -> Resize($dimensions);
		$result         = $$option{'imager'} -> Write($temp_file_name);
	}

Note: C<calculate_dimensions()> calls Get('width', 'height').

This means if you wish to intercept these calls with a custom object, your C<Image::Magick>-based object must respond to
these calls:

=over 4

=item Get()

=item Read()

=item Resize()

=item Write()

=back

=item options => {xpixels => 400, ypixels => 500}

If the $obj isa('Imager') you must pass in suitable parameters for C<Imager's> C<scale()> method.

Any such parameters are acceptable. I just used I<xpixels> and I<ypixels> during testing.

Here's what happens:

	if ($$option{'imager'} -> isa('Imager') )
	{
		my($result)     = $$option{'imager'} -> read(file => $old_file_name, type => $$meta_data{'extension'});
		my($new_image)  = $$option{'imager'} -> scale(%{$$option{'options'} });
		my($extension)  = $$meta_data{'extension'};
		$extension      = $extension ? ".$extension" : '';
		$temp_file_name = "$temp_file_name$extension";
		$result         = $new_image -> write(file => $temp_file_name, type => $$meta_data{'extension'});
	}

So, to intercept these calls, a descendent of C<Imager> must respond to these calls:

=over 4

=item read()

=item scale()

=item write()

=back

=back

This key (transform) is optional.

=back

=head1 Sample Code

Most of the features in C<CGI::Uploader> are demonstrated in samples shipped with the distro:

=over 4

=item Config data

Patch lib/CGI/Uploader/.ht.cgi.uploader.conf as desired.

This is used by C<CGI::Uploader::Config> and hence by C<CGI::Uploader::Test>.

=item CGI forms

Copy the directory htdocs/uploads/ to the doc root of your web server.

=item CGI scripts

Copy the files in cgi-bin/ to your cgi-bin directory.

As explained above, don't expect use.cgi.simple.pl to work.

Also, use.cgi.uploader.v2.pl will not run if you have installed V 3 over the top of V 2.

=item Run the CGI scripts

Point your web client at:

=over 4

=item /cgi-bin/use.cgi.pl

=item /cgi-bin/use.cgi.uploader.v3 pl

=back

You can enter 1 or 2 file names in each CGI form.

The code executed is actually in C<CGI::Uploader::Test>.

See the method I<use_cgi_uploader_v3()> in that module for one way of utilizing the data returned by
C<upload()>.

=back

=head1 Modules Used and Required

Both Build.PL and Makefile.PL list the modules used by C<CGI::Uploader>.

Further to those, user options can trigger the use of these modules:

=over 4

=item Config::IniFiles

If you use C<CGI::Uploader::Test>, it uses C<CGI::Uploader::Config>, which uses C<Config::IniFiles>.

=item DBD::Pg

I (Ron) used Postgres when writing and testing V 3, and hence I used C<DBD::Pg>.

Examine lib/CGI/Uploader/.ht.cgi.uploader.conf for details. This file is read in by C<CGI::Uploader::Config>.

=item DBD::SQLite

A quick test with SQLite worked, too.

The test only requires changing .ht.cgi.uploader.conf and re-running scripts/create.table.pl. E.g.:

	dsn=dbi:SQLite:dbname=/tmp/test
	password=
	table_name=uploads
	username=

Also, after running scripts/create.table.pl, use 'chmod a+w /tmp/test' so that the Apache daemon can
write to the database.

One last thing. SQLite does not interpret the function I<now()>; it just puts that string in the I<date_stamp>
column. Oh, well.

=item DBI

If you do not specify a I<manager> object, C<CGI::Uploader> uses C<DBI>.

=item DBIx::Admin::CreateTable

If you use C<CGI::Uploader::Test> to create the table, via scripts/create.table.pl, you'll need
C<DBIx::Admin::CreateTable>.

=item Digest::MD5

If you set the I<file_scheme> option to I<md5>, you'll need C<Digest::MD5>.

=item HTML::Template

If you want to run any of the test scripts in cgi-bin/, you'll need C<HTML::Template>.

=item Image::Magick

If you specify the I<transform> option without the I<imager> option, C<CGI::Uploader> use C<Imager::Magick>.

=back

=head1 FAQ

=over 4

=item Specifying the file name on the server

This feature is not provided, for various reasons.

One problem is sabotage.

Another problem is users specifying characters which are illegal in file names on the server.

In other words, this feature was considered and rejected.

=item API changes from V 2 to V 3

API changes between V 2 and V 3 are obviously enormous. A direct comparison doesn't make much sense.

However, here are some things to watch out for:

=over 4

=item Various columns have different (default) names

=item Default file extension

Under V 2, a file called 'x' would be saved by force with a name of 'x.bin'.

V 3 does not change file names, so 'x' will be stored in the database as 'x'.

=item The dot in the file extension

Under V 2, a file called 'x.png' would have '.png' stored in the extension column of the database.

V 3 only stores 'png'.

=item The id of the last record inserted

Under V 2, various mechanisms were used to retrieve this value.

V 3 calls $dbh -> last_insert_id(), unless of course you've circumvented this by supplying your own
I<manager> object.

=item The file name on the server

Under V 2, the permanent file name was not stored as part of the meta-data.

V 3 stores this information.

=item Datestamps

Under V 2, the datestamp of when the file was uploaded was not saved.

V 3 stores this information.

=item How come there is no update option like there was in V 2?

Errr, it's been renamed to C<delete()> and C<upload()>.

=back

=back

=head1 Changes

See Changes and Changelog.ini. The latter is machine-readable, using Module::Metadata::Changes.

=head1 Public Repository

V 3 is available from github: git:github.com/ronsavage/cgi--uploader.git

=head1 Authors

V 2 was written by Mark Stosberg <mark@summersault.com>.

V 3 was by Ron Savage <ron@savage.net.au>.

Ron's home page: http://savage.net.au/index.html

=head1 Licence

Artistic.

=cut
