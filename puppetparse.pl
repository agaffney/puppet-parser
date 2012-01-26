#!/usr/bin/perl

use strict;
use warnings;

package PuppetParser;

use Parse::Lex;
use Data::Dumper;

my @keywords = (
	"case",
	"class",
	"default",
	"define",
	"import",
	"if",
	"elsif",
	"else",
	"inherits",
	"node",
	"and",
	"or",
	"undef",
#	"false",
#	"true",
	"in",
	"include",
);

my @tokens = (
	"LLCOLLECT" => '<<\|',
	"RRCOLLECT" => '\|>>',
	"LCOLLECT" => '<\|',
	"RCOLLECT" => '\|>',
	"LBRACK" => '\[',
	"RBRACK" => '\]',
	"LBRACE" => '\{',
	"RBRACE" => '\}',
	"LPAREN" => '\(',
	"RPAREN" => '\)',
	"FARROW" => '=>',
	"APPENDS" => '\+=',
	"ISEQUAL" => '==',
	"GREATEREQUAL" => '>=',
	"GREATERTHAN" => '>',
	"LESSTHAN" => '<',
	"LESSEQUAL" => '<=',
	"NOTEQUAL" => '!=',
	"MATCH" => '=~',
	"EQUALS" => '=',
	"NOT" => '!',
	"COMMA" => ',',
	"DOT" => '\.',
	"AT" => '@',
	"IN_EDGE" => '->',
	"OUT_EDGE" => '<-',
	"IN_EDGE_SUB" => '~>',
	"OUT_EDGE_SUB" => '<~',
	"SEMIC" => ';',
	"QMARK" => '\?',
	"BACKSLASH" => '\\\\',
	"PARROW" => '\+>',
	"PLUS" => '\+',
	"MINUS" => '-',
	new Parse::Token::Delimited(Name => 'MLCOMMENT', Start => '/[*]', End => '[*]/' ),
	"REGEX", '\/[^/\n]*\/',
	"DIV" => '/',
	"TIMES" => '\*',
	"LSHIFT" => '<<',
	"RSHIFT" => '>>',
	"NOMATCH" => '!~',
	"CLASSREF" => '((::){0,1}[A-Z][-\w]*)+',
	"NUMBER" => '\b(?:0[xX][0-9A-Fa-f]+|0?\d+(?:\.\d+)?(?:[eE]-?\d+)?)\b',
	"NAME" => '((::)?[a-z0-9][-\w]*)(::[a-z0-9][-\w]*)*',
	"COMMENT" => '#.*',
#	"MLCOMMENT", qw(/\*(.*?)\*/), #m
	"RETURN", '\n',
	"COLON" => ':',
	"DOLLAR_VAR", '\$(::)?([-\w]+::)*[-\w]+',
	"VARIABLE", '(::)?([-\w]+::)*[-\w]+',
	new Parse::Token::Quoted(Name => 'SQUOTES', Handler => 'string', Quote => "'"),
	new Parse::Token::Quoted(Name => 'DQUOTES', Handler => 'string', Escape => '\\', Quote => '"'),
	"WHITESPACE" => '\s+',
	qw(ERROR  .*), sub {
		die "unknown token: " . $_[1] . "\n";
	}
);

my @object_classes = (
	'PuppetParser::Newline',
	'PuppetParser::Comment',
	'PuppetParser::MultilineComment',
	'PuppetParser::Class',
	'PuppetParser::FunctionCall',
	'PuppetParser::Resource',
	'PuppetParser::IfStatement',
	'PuppetParser::Include',
	'PuppetParser::VarAssignment',
	'PuppetParser::Node',
	'PuppetParser::Define',
	'PuppetParser::CaseStatement',
#	'PuppetParser::CaseCondition',
	'PuppetParser::DependencyChain',
#	'PuppetParser::ResourceRef',
);
my $default_object_class = 'PuppetParser::Simple';

sub new {
	my($class, %args) = @_;
	my $self = {
		parsed_tokens => [],
		num_parsed_tokens => 0,
		token_idx => 0,
		lexer => undef,
		buffer => '',
		indent => 0,
	};
	for(keys %args) {
		$self->{$_} = $args{$_};
	}
	bless($self, $class);
#	for(@object_classes) {
#		eval "use $_;";
#	}
	return $self;
}

sub output {
	my ($self, $output) = @_;
	my $buffer = $self->{tree}->output_children();
	$buffer =~ s/^\n+//s;
	$buffer =~ s/\n+$/\n/s;
	if(defined $output && $output ne '') {
		open FOO, "> $output" or die "Could not open output file $output: $!";
		print FOO $buffer;
		close FOO;
	} else {
		print $buffer;
	}
}

sub error {
	my ($self, $msg) = @_;
	$self->show_call_stack();
	print Dumper($self->cur_token());
	print STDERR "ERROR: ${msg} on line " . $self->cur_token()->{line} . " in file " . $self->{file} . "\n";
	exit 1;
}

sub parse {
	my ($self) = @_;

	my $file = $self->{file};
	open FOO, "< $file" or die "Can't open file $file: $!";

	#Parse::Lex->trace;
	#Parse::Lex->skip('');
	$self->{lexer} = Parse::Lex->new(@tokens);
	$self->{lexer}->from(\*FOO);

	# Read in and store tokens
	$self->read_tokens();

	# Start the process
	$self->{tree} = PuppetParser::Object->new(type => 'ROOT', level => -1, parser => $self);
	while($self->cur_token()) {
		my $foo = $self->scan_for_object($self->{tree});
		push @{$self->{tree}->{contents}}, $foo;
	}
}

sub transform_token_type {
	my ($self, $type, $text) = @_;
	if($type eq 'NAME') {
		if(grep(/^${text}$/, @keywords)) {
			$type = uc($text);
		}
	}
	return $type;
}

sub read_tokens {
	my ($self) = @_;
	while(1) {
		my $token = $self->{lexer}->next;
		if($self->{lexer}->eoi) {
			last;
		}
		push(@{$self->{parsed_tokens}}, { line => $self->{lexer}->line, type => $self->transform_token_type($token->name, $token->text), text => $token->text });
	}
	$self->{num_parsed_tokens} = scalar(@{$self->{parsed_tokens}});
	$self->{token_idx} = 0;
}

sub eof {
	my ($self) = @_;
	if(!defined $self->cur_token()) {
		return 1;
	}
	return 0;
}

sub cur_token {
	my ($self) = @_;
	return defined($self->{parsed_tokens}->[$self->{token_idx}]) ? $self->{parsed_tokens}->[$self->{token_idx}] : undef;
}

sub show_call_stack {
	my ($self) = @_;
	my ( $path, $line, $subr );
	my $max_depth = 30;
	my $i = 1;
	print "--- Begin stack trace ---\n";
	while ( (my @call_details = (caller($i++))) && ($i<$max_depth) ) {
		print "$call_details[1] line $call_details[2] in function $call_details[3]\n";
	}
	print "--- End stack trace ---\n";
}

sub next_token {
	my ($self) = @_;
	$self->{token_idx}++;
#	if($self->cur_token()->{type} eq 'COMMENT') {
#		print "next_token(): Found a comment - " . $self->cur_token()->{text} . "\n";
#		$self->show_call_stack();
#	}
	return $self->cur_token();
}

sub inject_tokens {
	# This function exists purely to facilitate the breaking up of multiple resource definitions in a single block
	my ($self, $tokens) = @_;
	splice(@{$self->{parsed_tokens}}, $self->{token_idx}, 0, @{$tokens});
	$self->{num_parsed_tokens} = scalar(@{$self->{parsed_tokens}});
}

sub get_token_idx {
	my ($self) = @_;
	return $self->{token_idx};
}

sub set_token_idx {
	my ($self, $idx) = @_;
	$self->{token_idx} = $idx;
}

sub parse_case {
	my ($self) = @_;
	my $obj = { type => 'case', 'condition' => undef, contents => [] };
	$self->next_token();
	$obj->{condition} = $self->parse_value(['LBRACE']);
	if($self->cur_token()->{type} ne 'LBRACE') {
		print "ERROR: something went horribly wrong parsing a CASE statement\n";
		return;
	}
	$self->add_to_parent($obj);
}

sub output_case {
	my ($self, $obj) = @_;
	my $buf = $self->newline() . $self->indent() . 'case ';
	for my $foo (@{$obj->{condition}}) {
		$buf .= $self->output_simple($foo) . ' ';
	}
	$buf .= '{' . $self->newline();
	$self->{indent}++;
	for my $child (@{$obj->{contents}}) {
		$buf .= $self->output_object($child);
	}
	$self->{indent}--;
	$buf .= $self->newline() . $self->indent() . '}' . $self->newline();
	return $buf;
}

sub parse_case_condition {
	my ($self) = @_;
	my $obj = { type => 'case_condition', condition => undef, contents => [] };
	while(my $token = $self->cur_token()) {
		if($token->{type} eq 'COLON') {
			$self->next_token();
			next;
		}
		if($token->{type} eq 'LBRACE') {
			last;
		}
		push @{$obj->{condition}}, $token;
		$self->next_token();
	}
	$self->add_to_parent($obj);
}

sub output_case_condition {
	my ($self, $obj) = @_;
	my $buf = $self->newline() . $self->indent();
	$buf .= join(' ', map { $self->output_object($_, 1) } @{$obj->{condition}});
	$buf .= ': {' . $self->newline();
	$self->{indent}++;
        for my $child (@{$obj->{contents}}) {
		$buf .= $self->output_object($child);
	}
	$self->{indent}--;
	$buf .= $self->indent() . '}' . $self->newline();
	return $buf;
}

sub output_resource_definition {
	my ($self, $obj) = @_;
	my $buf = $self->newline() . $self->indent() . $obj->{restype} . ' { ';
	my $tmp = '';
	for (@{$obj->{title}}) {
		if($tmp ne '') {
			$tmp .= ' ';
		}
		$tmp .= $self->output_object($_);
	}
	$buf .= $tmp . ':';
	if(scalar(@{$obj->{attribs}}) > 0) {
		$buf .= $self->newline();
		$self->{indent}++;
		my $max_key_len = $self->max_key_length($obj->{attribs});
		for my $attr (@{$obj->{attribs}}) {
			$buf .= $self->indent() . sprintf("%-${max_key_len}s", $attr->{name}) . ' => ';
			#	. $self->output_object($attr->{value}) . ',' . "\n"
			my $tmp = '';
			for (@{$attr->{value}}) {
				if($tmp ne '') {
					$tmp .= ' ';
				}
				$tmp .= $self->output_object($_, 1);
			}
			$buf .= $tmp . ',' . "\n";
		}
		$self->{indent}--;
		$buf .= $self->indent();
	} else {
		$buf .= ' ';
	}
	$buf .= '}' . $self->newline();
	return $buf;
}

sub match_token_sequence {
	my ($self, $seq, $ignore) = @_;
	if(!defined $ignore) {
		$ignore = ['RETURN', 'COMMENT', 'MLCOMMENT'];
	}
	my $orig_token = $self->get_token_idx();
	my $cur_token = $self->cur_token();
	TYPE: for my $type (@{$seq}) {
		$cur_token = $self->cur_token();
		for(@{$ignore}) {
			if($cur_token->{type} eq $_) {
				print "match_token_sequence(): skipping token type " . $cur_token->{type} . "\n";
				# The next token is of a type we want to ignore
				$cur_token = $self->next_token();
				next TYPE;
			}
		}
		if($cur_token->{type} ne $type) {
			$self->set_token_idx($orig_token);
			return 0;
		}
		$self->next_token();
	}
	# We found a match
	$self->set_token_idx($orig_token);
	return 1;
}

sub scan_for_token {
	my ($self, $types, $ignore) = @_;
	if(!defined $ignore) {
		$ignore = [];
	}
	TOKEN: while(my $token = $self->cur_token()) {
		for(@{$ignore}) {
			if($token->{type} eq $_) {
				# The next token is of a type we want to ignore
				$self->next_token();
				next TOKEN;
			}
		}
		for(@{$types}) {
			if($token->{type} eq $_) {
				return 1;
			}
		}
		# Could not find the expected token
		return 0;
	}
}

sub scan_for_object {
	my ($self, $parent) = @_;
	my $token = $self->cur_token();
#	print "Line: ", $token->{line}, ", ";
#	print "Type: ", $token->{type}, ", ";
#	print "Content:->", $token->{text}, "<-\n";
	my $orig_token = $self->get_token_idx();
	my $cur_token = undef;
	for my $package (@object_classes) {
		my $foo = $package->new(parent => $parent);
		if(!defined $foo) {
			next;
		}
		return $foo;
	}
	$self->set_token_idx($orig_token);
	# We don't know how to handle this
	if(defined $self->cur_token()) {
		$self->error("Unexpected token '" . $self->cur_token()->{text} . "'");
	}
}

package PuppetParser::Object;

use Data::Dumper;

our %defaults = (
	inner_spacing => 0,
	outer_spacing => 0,
);

sub new {
	my ($class, %args) = @_;
	my $self = { contents => [] };
	bless($self, $class);
	for(keys %args) {
		$self->{$_} = $args{$_};
	}
	$self->apply_defaults();
	my $parse = $self->parse();
	if(defined $parse && $parse == 0) {
#		print "${class}::new(): no, it's not a $class\n";
		return undef;
	}
	if(!defined $self->{type} || $self->{type} ne 'ROOT') {
		$self->{parser} = undef;
		$self->{parent} = undef;
#		$self->dump();
	}
#	print "${class}::new(): yes, it's a $class\n";
	return $self;
}

sub apply_defaults {
	my ($self, $def) = @_;
	if(!defined $def) {
		$def = \%defaults;
	}
	for(keys %{$def}) {
		if(!defined $self->{$_}) {
			$self->{$_} = $def->{$_};
		}
	}
	if(!defined $self->{level}) {
		if(defined $self->{parent} && defined $self->{parent}->{level}) {
			$self->{level} = $self->parent()->{level} + 1;
		}
	}
	if(!defined $self->{parser}) {
		if(defined $self->{parent} && defined $self->{parent}->{parser}) {
			$self->{parser} = $self->{parent}->{parser};
		}
	}
}

sub get_parser_data {
	return [];
}

sub dump {
	my ($self) = @_;
	my $d = Data::Dumper->new([$self], ['tree']);
	$d->Indent(4);
#	$d->Seen({ '*parser' => $self->{parser} });
	print $d->Dump;
}

sub parser_any {
	my ($self, $parser, $node) = @_;
	my $class = ref $self;
	for my $node (@{$node->{members}}) {
		my $foo = $self->check_parser_node($parser, $node);
		if(defined $foo) {
			return $foo;
		}
	}
	return undef;
}

sub parser_group {
	my ($self, $parser, $node) = @_;
	my $class = ref $self;
	my $ret = {};
	for my $node (@{$node->{members}}) {
		my $foo = $self->check_parser_node($parser, $node);
		if(!defined $foo) {
			if(!defined $node->{optional} || $node->{optional} == 0) {
				return undef;
			}
		}
		for(keys %{$foo}) {
			$ret->{$_} = $foo->{$_};
		}
	}
	return $ret;
}

sub parser_class {
	my ($self, $parser, $node) = @_;
	my $class = ref $self;
	if(ref $node->{class} ne 'ARRAY') {
		$node->{class} = [ $node->{class} ];
	}
	my $ret = {};
	my %args = ( parent => $self );
	if(defined $node->{args}) {
		for(keys %{$node->{args}}) {
			$args{$_} = $node->{args}->{$_};
		}
	}
	my $foo = undef;
	for(@{$node->{class}}) {
		$foo = $_->new(%args);
		if(defined $foo) {
			last;
		}
	}
	if(!defined $foo) {
		return undef;
	}
	if(defined $node->{name}) {
		$ret->{$node->{name}} = $foo;
	}
	return $ret;
}

sub parser_block {
	my ($self, $parser, $node) = @_;
	my $class = ref $self;
	if(!$parser->scan_for_token(['LBRACE'])) {
		return undef;
	}
	$parser->next_token();
	my $ret = { contents => [] };
	while(1) {
		if($self->{parser}->scan_for_token(['RBRACE'])) {
			$self->{parser}->next_token();
			last;
		}
		if($self->{parser}->scan_for_token(['RETURN'])) {
			$self->{parser}->next_token();
			next;
		}
		if($self->{parser}->eof()) {
			$self->{parser}->error("Unexpected end of file");
		}
		my $foo = $self->{parser}->scan_for_object($self);
		if(!defined $foo) {
			return undef;
		}
		push @{$ret->{contents}}, $foo;
	}
	return $ret;
}

sub parser_token {
	my ($self, $parser, $node) = @_;
	my $class = ref $self;
	if(ref $node->{token} ne 'ARRAY') {
		$node->{token} = [ $node->{token} ];
	}
	if($parser->scan_for_token($node->{token})) {
		my $ret = {};
		my $child = PuppetParser::Simple->new(parent => $self);
		if(defined $node->{name}) {
			$ret->{$node->{name}} = $child;
		}
		return $ret;
	}
	return undef;
}

sub check_parser_node {
	my ($self, $parser, $node) = @_;
#	use Data::Dumper;
	my $class = ref $self;
	my $parser_func = 'parser_' . $node->{type};
	if($node->{type} ne 'group' && (!defined $node->{flags} || !defined $node->{flags}->{skip_return} || $node->{flags}->{skip_return} == 1)) {
		while(1) {
			if($parser->scan_for_token(['RETURN'])) {
				$parser->next_token();
			} else {
				last;
			}
		}
	}
	if(!defined $parser->cur_token()) {
		return undef;
	}
#	my $token = $parser->cur_token();
#	print "${class}::check_parser_node(): cur_token - type=" . $token->{type} . ", text=" . $token->{text} . ", line=" . $token->{line} . "\n";
	my $orig_token = $parser->get_token_idx();
	if($self->can($parser_func)) {
		my $ret = {};
		while(1) {
#			print "Calling $parser_func()\n";
			my $foo = $self->$parser_func($parser, $node);
			if(!defined $foo) {
				if(defined $node->{many} && $node->{many} == 1) {
#					print Dumper($ret);
					if(scalar(keys %{$ret}) > 0) {
						last;
					}
				}
				if(!defined $node->{optional} || $node->{optional} == 0) {
					$parser->set_token_idx($orig_token);
					return undef;
				}
				last;
			}
			for(keys %{$foo}) {
				if(defined $ret->{$_}) {
					if(ref $ret->{$_} ne 'ARRAY') {
						$ret->{$_} = [ $ret->{$_} ];
					}
					push @{$ret->{$_}}, $foo->{$_};
				} else {
					$ret->{$_} = $foo->{$_};
				}
			}
#			print "${class}::check_parser_node(): Return now looks like:\n";
#			print Dumper($ret);
			if(!defined $node->{many} || $node->{many} == 0) {
				last;
			}
		}
		return $ret;
	}
	print STDERR "ERROR: Parsing function ${parser_func}() doesn't exist yet\n";
	return undef;
}

sub parse {
	my ($self) = @_;
	my $foo = $self->check_parser_node($self->{parser}, { type => 'group', members => $self->get_parser_data() });
	if(!defined $foo) {
		return 0;
	}
	for(keys %{$foo}) {
		$self->{$_} = $foo->{$_};
	}
	return 1;
}

sub parent {
	my ($self) = @_;
	return $self->{parent};
}

sub indent {
	my ($self, $level) = @_;
	if(!defined $level) {
		$level = $self->{level};
	}
	return '  ' x $level;
}

sub nl {
	return "\n";
}

sub output {
	my ($self) = @_;
	return $self->indent() . "<Placeholder for " . $self . ">" . $self->nl();
}

sub output_children {
	my ($self) = @_;
	my $buf = '';
	if($self->{inner_spacing}) {
		$buf .= "\n";
	}
	if(!defined $self->{contents}) {
		return '';
	}
	for(@{$self->{contents}}) {
		my $child_output .= $_->output();
		if($_->{outer_spacing}) {
			$child_output = "\n" . $child_output . "\n";
		}
		$buf .= $child_output;
	}
	if($self->{inner_spacing}) {
		$buf .= "\n";
	}
	# Formatting fixups
	$buf =~ s/\n{3,}/\n\n/gs;
	$buf =~ s/}\n\n\s*(else|elsif) /} else /gs;
	return $buf;
}

package PuppetParser::Simple;

our @ISA = 'PuppetParser::Object';

sub parse {
	my ($self) = @_;
	my $token = $self->{parser}->cur_token();
	$self->{type} = $token->{type};
	$self->{text} = $token->{text};
	$self->{parser}->next_token();
}

sub output {
	# This is a shell for simple objects. This will be overriden in more complex types
	my ($self) = @_;
	return defined $self->{text} ? $self->{text} : '';
}

package PuppetParser::Newline;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => 'RETURN', flags => { skip_return => 0 } },
	];
	return $parser_data;
}

sub output {
	return '';
}

package PuppetParser::Comment;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => 'COMMENT', name => 'comment' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $comment = $self->{comment}->output();
	$comment =~ s/^[#\s]+//;
	return $self->indent() . '# ' . $comment . $self->nl();
}

package PuppetParser::MultilineComment;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => 'MLCOMMENT', name => 'comment' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	return $self->indent() . $self->{comment} . $self->nl();
}

package PuppetParser::ArrayRef;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => 'DOLLAR_VAR', name => 'varname' },
		{ type => 'token', token => 'LBRACK' },
		{ type => 'class', class => 'PuppetParser::Expression', args => { term => ['RBRACK'] }, name => 'inner' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $buf = $self->{varname}->output() . '[' . $self->{inner}->output() . ']';
	return $buf;
}

package PuppetParser::ResourceRef;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => ['CLASSREF'], name => 'restype' },
		{ type => 'token', token => ['LBRACK'] },
		{ type => 'class', class => 'PuppetParser::Expression', args => { term => ['RBRACK'] }, name => 'inner' },
		{ type => 'token', token => ['RBRACK'] },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $buf = $self->{restype}->output() . '[' . $self->{inner}->output() . ']';
	return $buf;
}

package PuppetParser::List;

our @ISA = 'PuppetParser::Object';

sub apply_defaults {
	my ($self) = @_;
	$self->SUPER::apply_defaults({ start => 'LBRACK', end => 'RBRACK' });
}

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => 'LBRACK' },
		{ type => 'class', class => ['PuppetParser::ListElement', 'PuppetParser::Comment'], many => 1, name => 'items' },
		{ type => 'token', token => ['RBRACK'] },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $buf = '[' . $self->nl();
	if(ref $self->{items} ne 'ARRAY') {
		$self->{items} = [ $self->{items} ];
	}
	for(@{$self->{items}}) {
		if($_->isa('PuppetParser::Comment')) {
			$buf .= $_->output();
		} else {
			$buf .= $self->indent($self->{level} + 1) . $_->output() . $self->nl();
		}
	}
	$buf .= $self->indent() . ']';
	return $buf;
}

package PuppetParser::Hash;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => 'LBRACE' },
		{ type => 'class', class => ['PuppetParser::KeyValuePair', 'PuppetParser::Comment'], name => 'items', many => 1 },
		{ type => 'token', token => 'RBRACE' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $max_key_len = 0;
	for(@{$self->{items}}) {
		if($_->can('key_len')) {
			my $key_len = $_->key_len();
			if($key_len > $max_key_len) {
				$max_key_len = $key_len;
			}
		}
	}
	my $buf = '{';
	if(scalar(@{$self->{items}}) > 0) {
		$buf .= $self->nl();
	}
	for(@{$self->{items}}) {
		if($_->can('set_max_key_len')) {
			$_->set_max_key_len($max_key_len);
		}
		$buf .= $_->output();
	}
	$buf .= (scalar(@{$self->{items}}) > 0 ? $self->indent() : ' ') . '}' . $self->nl();
	return $buf;
}

package PuppetParser::Expression;

our @ISA = 'PuppetParser::Object';

sub parse {
	my ($self) = @_;
	my $packages = ['PuppetParser::ResourceRef', 'PuppetParser::ArrayRef', 'PuppetParser::FunctionCall', 'PuppetParser::List', 'PuppetParser::Hash', 'PuppetParser::Selector'];
	$self->{parts} = [];
	TOKEN: while(1) {
		if($self->{parser}->scan_for_token($self->{term})) {
			last;
		}
		if($self->{parser}->scan_for_token(['RBRACE'])) {
			# This is a total hack, but it works
			return 0;
		}
		if($self->{parser}->scan_for_token(['RETURN'])) {
			$self->{parser}->next_token();
			next;
		}
		for my $package (@{$packages}) {
			my $foo = $package->new(parent => $self, embed => 1, level => $self->{level} - 1);
			if(defined $foo) {
				push @{$self->{parts}}, $foo;
				next TOKEN;
			}
		}
		push @{$self->{parts}}, PuppetParser::Simple->new(parent => $self);
	}
	if(scalar(@{$self->{parts}}) == 0) {
		return 0;
	}
	return 1;
}

sub output {
	my ($self) = @_;
	my $buf = join(' ', map { $_->output() } @{$self->{parts}});
	return $buf;
}

package PuppetParser::Selector;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => 'DOLLAR_VAR', name => 'varname' },
		{ type => 'token', token => 'QMARK' },
		{ type => 'token', token => 'LBRACE' },
		{ type => 'class', class => ['PuppetParser::KeyValuePair', 'PuppetParser::Comment'], name => 'items', many => 1 },
		{ type => 'token', token => 'RBRACE' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $max_key_len = 0;
	if(ref $self->{items} ne 'ARRAY') {
		$self->{items} = [ $self->{items} ];
	}
	for(@{$self->{items}}) {
		if($_->can('key_len')) {
			my $key_len = $_->key_len();
			if($key_len > $max_key_len) {
				$max_key_len = $key_len;
			}
		}
	}
	my $buf = $self->{varname}->output() . ' ? {';
	if(scalar(@{$self->{items}}) > 0) {
		$buf .= $self->nl();
	}
	for(@{$self->{items}}) {
		if($_->can('set_max_key_len')) {
			$_->set_max_key_len($max_key_len);
		}
		$buf .= $_->output();
	}
	$buf .= (scalar(@{$self->{items}}) > 0 ? $self->indent() : ' ') . '}';
	return $buf;
}


package PuppetParser::CaseStatement;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => 'CASE' },
		{ type => 'token', token => 'DOLLAR_VAR', name => 'casevar' },
		{ type => 'token', token => 'LBRACE' },
		{ type => 'class', class => ['PuppetParser::CaseCondition', 'PuppetParser::Comment'], many => 1, name => 'conditions' },
		{ type => 'token', token => 'RBRACE' },
	];
	return $parser_data;
}

sub apply_defaults {
	my ($self) = @_;
	$self->SUPER::apply_defaults({ inner_spacing => 0, outer_spacing => 1 });
}

sub output {
	my ($self) = @_;
	my $buf = $self->indent() . 'case ' . $self->{casevar}->output() . ' {' . $self->nl();
	if(ref $self->{conditions} ne 'ARRAY') {
		$self->{conditions} = [ $self->{conditions} ];
	}
	for(@{$self->{conditions}}) {
		$buf .= $_->output();
	}
	$buf .= $self->indent() . '}' . $self->nl();
	return $buf;
}

package PuppetParser::Node;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => 'NODE' },
#		{ type => 'token', token => ['NAME', 'DEFAULT', 'REGEX', 'SQUOTES', 'DQUOTES'], name => 'nodename' },
		{ type => 'class', class => 'PuppetParser::Expression', args => { term => ['LBRACE'] }, name => 'nodename' },
		{ type => 'group', optional => 1, members => [
			{ type => 'token', token => 'INHERITS' },
			{ type => 'token', token => ['NAME', 'DEFAULT', 'REGEX', 'SQUOTES', 'DQUOTES'], name => 'inherits' },
		]},
		{ type => 'block', name => 'contents' },
	];
	return $parser_data;
}

sub apply_defaults {
	my ($self) = @_;
	$self->SUPER::apply_defaults({ outer_spacing => 1 });
}

sub output {
	my ($self) = @_;
	my $buf = $self->indent() . 'node ' . $self->{nodename}->output() . ' {' . $self->nl();
	$buf .= $self->output_children();
	$buf .= $self->indent() . '}' . $self->nl();
	return $buf;
}

package PuppetParser::CaseCondition;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'class', class => 'PuppetParser::Expression', args => { term => ['COLON'] }, name => 'casecondition' },
		{ type => 'token', token => 'COLON' },
		{ type => 'block', name => 'contents' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $buf = $self->indent() . $self->{casecondition}->output() . ': {' . $self->nl();
	$buf .= $self->output_children();
	$buf .= $self->indent() . '}' . $self->nl();
	return $buf;
}

package PuppetParser::KeyValuePair;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => ['NAME', 'DEFAULT', 'REGEX', 'SQUOTES', 'DQUOTES', 'NUMBER'], name => 'key' },
		{ type => 'token', token => ['FARROW', 'PARROW'], name => 'arrow' },
		{ type => 'class', class => 'PuppetParser::Expression', args => { term => ['COMMA', 'SEMIC', 'RBRACE'] }, name => 'value' },
		{ type => 'token', token => ['COMMA', 'SEMIC'], optional => 1 },
	];
	return $parser_data;
}

sub key_len {
	my ($self) = @_;
	return length($self->{key}->output());
}

sub set_max_key_len {
	my ($self, $len) = @_;
	$self->{max_key_len} = $len;
}

sub output {
	my ($self) = @_;
	my $buf = $self->indent() . sprintf('%-' . $self->{max_key_len} . 's', $self->{key}->output()) . ' => ' . $self->{value}->output() . ',' . $self->nl();
	return $buf;
}

package PuppetParser::ArgumentList;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my ($self) = @_;
	my $parser_data = [
		{ type => 'token', token => 'LPAREN' },
		{ type => 'class', class => 'PuppetParser::Expression', args => { term => ['RPAREN'] }, optional => 1, name => 'args' },
		{ type => 'token', token => 'RPAREN' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $buf = '(';
	if(defined $self->{args}) {
		$buf .= $self->{args}->output();
	}
	$buf .= ')';
	return $buf;
}

package PuppetParser::ListElement;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'class', class => 'PuppetParser::Expression', args => { term => ['COMMA', 'RBRACK'] }, name => 'value' },
		{ type => 'token', token => 'COMMA', optional => 1 },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $buf = $self->{value}->output() . ',';
	return $buf;
}

package PuppetParser::Class;

use Data::Dumper;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my ($self) = @_;
	my $parser_data = [
		{ type => 'token', token => 'CLASS' },
		{ name => 'classname', type => 'token', token => 'NAME' },
		{ name => 'args', type => 'class', class => 'PuppetParser::ArgumentList', optional => 1 },
		{ type => 'group', optional => 1, members => [
			{ type => 'token', token => 'INHERITS' },
			{ name => 'inherits', type => 'token', token => 'NAME' },
			], },
		{ name => 'contents', type => 'block' },
	];
	return $parser_data;
}

sub apply_defaults {
	my ($self) = @_;
	$self->SUPER::apply_defaults({ inner_spacing => 1, outer_spacing => 1 });
}

sub output {
	my ($self) = @_;
	my $buf = $self->indent() . 'class ' . $self->{classname}->output();
	if(defined $self->{args}) { #scalar(@{$self->{args}}) > 0) {
		$buf .= ' (';
		for(@{$self->{args}}) {
			$buf .= $_->output() . ', ';
		}
		$buf =~ s/, $//;
		$buf .= ')';
	}
	$buf .= ' {' . $self->nl();

	$buf .= $self->output_children();
	$buf .= '}' . $self->nl();
	return $buf;
}

package PuppetParser::Define;

our @ISA = 'PuppetParser::Object';

sub apply_defaults {
	my ($self) = @_;
	$self->SUPER::apply_defaults({ inner_spacing => 1, outer_spacing => 1 });
}

sub get_parser_data {
	my ($self) = @_;
	my $parser_data = [
		{ type => 'token', token => 'DEFINE' },
		{ name => 'defname', type => 'token', token => 'NAME' },
		{ name => 'args', type => 'class', class => 'PuppetParser::ArgumentList', optional => 1 },
		{ name => 'contents', type => 'block' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $buf = $self->indent() . 'define ' . $self->{defname}->output();
	if(defined $self->{args}) {
		$buf .= $self->{args}->output();
	}
	$buf .= ' {' . $self->nl();
	$buf .= $self->output_children();
	$buf .= $self->indent() . '}' . $self->nl();
	return $buf;
}

package PuppetParser::FunctionCall;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => ['NAME'], name => 'funcname' },
		{ type => 'class', class => 'PuppetParser::ArgumentList', name => 'args' },
	];
	return $parser_data;
}

#sub apply_defaults {
#	my ($self) = @_;
#	$self->SUPER::apply_defaults({ outer_spacing => 1 });
#}

sub output {
	my ($self) = @_;
	my $buf = ($self->{embed} ? '' : $self->indent()) . $self->{funcname}->output();
	if(defined $self->{args}) {
		$buf .= $self->{args}->output();
	}
	$buf .= ($self->{embed} ? '' : $self->nl());
	return $buf;
}

package PuppetParser::IfStatement;

our @ISA = 'PuppetParser::Object';

sub apply_defaults {
	my ($self) = @_;
	$self->SUPER::apply_defaults({ inner_spacing => 0, outer_spacing => 1 });
}

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => ['IF', 'ELSE', 'ELSIF'], name => 'variant' },
		{ type => 'class', class => 'PuppetParser::Expression', args => { term => ['LBRACE'] }, name => 'condition', optional => 1 },
		{ type => 'block', name => 'contents' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $buf = $self->indent() . $self->{variant}->output() . (defined $self->{condition} ? (' ' . $self->{condition}->output()) : '') . ' {' . $self->nl();
	$buf .= $self->output_children();
	$buf .= $self->indent() . '}' . $self->nl();
	return $buf;
};

package PuppetParser::Include;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => ['INCLUDE', 'IMPORT'], name => 'funcname' },
		{ type => 'token', token => ['NAME', 'SQUOTES', 'DQUOTES', 'DOLLAR_VAR'], name => 'arg' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	return $self->indent() . $self->{funcname}->output() . ' ' . $self->{arg}->output() . $self->nl();
}

package PuppetParser::VarAssignment;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'token', token => 'DOLLAR_VAR', name => 'varname' },
		{ type => 'token', token => 'EQUALS' },
		{ type => 'class', class => 'PuppetParser::Expression', args => { term => ['RETURN', 'RBRACE'] }, name => 'value' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	return $self->indent() . $self->{varname}->output() . ' = ' . $self->{value}->output() . $self->nl();
}

package PuppetParser::DependencyChainPiece;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'class', class => ['PuppetParser::ResourceRef'], name => 'ref' },
		{ type => 'token', token => ['IN_EDGE', 'OUT_EDGE'], name => 'arrow' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $buf = $self->{ref}->output() . ' ' . $self->{arrow}->output();
	return $buf;
}

package PuppetParser::DependencyChain;

our @ISA = 'PuppetParser::Object';

sub apply_defaults {
	my ($self) = @_;
	$self->SUPER::apply_defaults({ outer_spacing => 1 });
}

sub get_parser_data {
	my $parser_data = [
		{ type => 'class', class => 'PuppetParser::DependencyChainPiece', name => 'items' },
		{ type => 'class', class => 'PuppetParser::ResourceRef', name => 'lastitem' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $buf = $self->indent();
	if(ref $self->{items} ne 'ARRAY') {
		$self->{items} = [ $self->{items} ];
	}
	for(@{$self->{items}}) {
		$buf .= $_->output() . ' ';
	}
	$buf .= $self->{lastitem}->output();
	$buf .= $self->nl();
	return $buf;
}

package PuppetParser::ResourceTitle;

our @ISA = 'PuppetParser::Object';

sub get_parser_data {
	my $parser_data = [
		{ type => 'any', name => 'restitle', members => [
			{ type => 'token', token => ['NAME', 'SQUOTES', 'DQUOTES', 'DOLLAR_VAR'], name => 'restitle' },
			{ type => 'class', class => ['PuppetParser::ResourceRef', 'PuppetParser::List'], name => 'restitle' },
		]},
		{ type => 'token', token => 'COLON' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my $buf = $self->{restitle}->output() . ':';
	return $buf;
}

package PuppetParser::Resource;

our @ISA = 'PuppetParser::Object';

sub apply_defaults {
	my ($self) = @_;
	$self->SUPER::apply_defaults({ inner_spacing => 1, outer_spacing => 1 });
}

sub get_parser_data {
	my ($self) = @_;
	my $parser_data = [
		{ type => 'token', token => 'AT', optional => 1, name => 'virtual' },
		{ type => 'token', token => 'AT', optional => 1, name => 'exported' },
		{ type => 'any', name => 'restype', members => [
			{ type => 'class', class => 'PuppetParser::ResourceRef', name => 'restype' },
			{ type => 'token', token => ['NAME', 'CLASSREF', 'CLASS'], name => 'restype' },
		]},
		{ type => 'group', optional => 1, members => [
			{ type => 'token', token => 'LCOLLECT' },
			{ type => 'class', class => 'PuppetParser::Expression', args => { term => ['RCOLLECT'] }, optional => 1, name => 'tags' },
			{ type => 'token', token => 'RCOLLECT' },
		]},
		{ type => 'token', token => 'LBRACE' },
		{ type => 'class', class => ['PuppetParser::KeyValuePair', 'PuppetParser::ResourceTitle', 'PuppetParser::Comment'], name => 'items', many => 1 },
		{ type => 'token', token => 'RBRACE' },
	];
	return $parser_data;
}

sub output {
	my ($self) = @_;
	my @resources;
	my $res = {};
	if(ref $self->{items} ne 'ARRAY') {
		$self->{items} = [ $self->{items} ];
	}
	for(@{$self->{items}}) {
		if($_->isa('PuppetParser::ResourceTitle')) {
			if(defined $res->{title}) {
				push @resources, $res;
				$res = {};
				$res->{title} = $_;
				next;
			}
			$res->{title} = $_;
			next;
		}
		if(!defined $res->{items}) {
			$res->{items} = [];
		}
		push @{$res->{items}}, $_;
	}
	push @resources, $res;
	my $buf = '';
	for my $resource (@resources) {
		$buf .= $self->indent() . (defined $self->{special} ? $self->{special} : '') . (defined $self->{virtual} ? $self->{virtual}->output() : '') . (defined $self->{exported} ? $self->{exported}->output() : '') . $self->{restype}->output();
		if(defined $self->{collect}) {
			$buf .= ' <<| ' . $self->{collect}->output() . ' |>>';
		}
		$buf .= ' { ';
		if(defined $resource->{title}) {
			$buf .= $resource->{title}->output();
		}
		if(defined $resource->{items}) {
			my $max_key_len = 0;
			for(@{$resource->{items}}) {
				if($_->can('key_len')) {
					my $key_len = $_->key_len();
					if($key_len > $max_key_len) {
						$max_key_len = $key_len;
					}
				}
			}
			$buf .= $self->nl();
			for(@{$resource->{items}}) {
				if($_->can('set_max_key_len')) {
					$_->set_max_key_len($max_key_len);
				}
				$buf .= $_->output();
			}
		}
		$buf .= (defined $resource->{items} ? $self->indent() : ' ') . '}' . $self->nl() . $self->nl();
	}
	return $buf;
}

package main;

$| = 1;

use Getopt::Std;

# Flags
my %options;
my $output = '';
my $debug = 0;

# Parse options
my $result = getopts('do:', \%options);
if(defined $options{'o'}) {
	$output = $options{'o'};
}
if(defined $options{'d'}) {
	$debug = $options{'d'};
}
my $file = shift;

print "Parsing $file\n";
my $parser = PuppetParser->new(file => $file, debug => $debug);
$parser->parse();
$parser->output($output);
