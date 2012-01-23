#!/usr/bin/perl

use strict;
use warnings;

package PuppetParser;

use Parse::Lex;
use Data::Dumper;
use JSON;

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
	"false",
	"true",
	"in",
	"include",
);

my @tokens = (
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
	"EQUALS" => '=',
	"NOT" => '!',
	"COMMA" => ',',
	"DOT" => '\.',
	"COLON" => ':',
	"AT" => '@',
	"IN_EDGE" => '->',
	"OUT_EDGE" => '<-',
	"IN_EDGE_SUB" => '~>',
	"OUT_EDGE_SUB" => '<~',
	"LLCOLLECT" => '<<\|',
	"RRCOLLECT" => '\|>>',
	"LCOLLECT" => '<\|',
	"RCOLLECT" => '\|>',
	"SEMIC" => ';',
	"QMARK" => '\?',
	"BACKSLASH" => '\\\\',
	"PARROW" => '\+>',
	"PLUS" => '\+',
	"MINUS" => '-',
	"REGEX", '\/[^/\n]*\/',
	"DIV" => '/',
	"TIMES" => '\*',
	"LSHIFT" => '<<',
	"RSHIFT" => '>>',
	"MATCH" => '=~',
	"NOMATCH" => '!~',
	"CLASSREF" => '((::){0,1}[A-Z][-\w]*)+',
	"NUMBER", '\b(?:0[xX][0-9A-Fa-f]+|0?\d+(?:\.\d+)?(?:[eE]-?\d+)?)\b',
	"NAME", '((::)?[a-z0-9][-\w]*)(::[a-z0-9][-\w]*)*',
	new Parse::Token::Simple(Name => "COMMENT", Regex => '#.*', Sub => sub {
		my ($token, $string) = @_;
		$string =~ s/^[# ]+//;
		return $string;
	}),
	new Parse::Token::Delimited(Name => 'MLCOMMENT', Start => '/[*]', End => '[*]/' ),
#	"MLCOMMENT", qw(/\*(.*?)\*/), #m
	"RETURN", '\n',
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
	'PuppetParser::Class',
	'PuppetParser::Resource',
	'PuppetParser::Include',
	'PuppetParser::FunctionCall',
	'PuppetParser::IfStatement',
	'PuppetParser::VarAssignment',
	'PuppetParser::Define',
	'PuppetParser::Comment',
	# Leave this one at the bottom, so its patterns match last
	'PuppetParser::Simple',
);
my $default_object_class = 'PuppetParser::Simple';

my @parse_patterns = (
	{
		patterns => [['CASE']],
		func => 'parse_case',
	},
	{
		patterns => [
			['SQUOTES', 'COLON', 'LBRACE'],
			['DQUOTES', 'COLON', 'LBRACE'],
			['NAME', 'COLON', 'LBRACE'],
			['REGEX', 'COLON', 'LBRACE'],
			['DEFAULT', 'COLON', 'LBRACE'],
		],
		func => 'parse_case_condition',
	},
	{
		patterns => [['NAME', 'LBRACK']],
		func => 'parse_resource_override',
	},
);

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

sub output_json {
	my ($self, $output) = @_;
	my $json = JSON->new->pretty(1)->encode($self->{tree});
	if(defined $output && $output ne '') {
		open FOO, "> $output" or die "Could not open output file $output: $!";
		print FOO $json;
		close FOO;
	} else {
		print $json;
	}
}

sub output {
	my ($self, $output) = @_;
	my $buffer = $self->{tree}->output();
	if(defined $output && $output ne '') {
		open FOO, "> $output" or die "Could not open output file $output: $!";
		print FOO $buffer;
		close FOO;
	} else {
		print $buffer;
	}
}

sub output_object {
	my ($self, $obj, $embed) = @_;
	$embed = 0 if(!defined $embed);
#	print Dumper($obj);
	my $func_name = 'output_' . $obj->{type};
	if(PuppetParser->can($func_name)) {
		print "output_object(): calling $func_name()\n";
		return $self->$func_name($obj, $embed);
	} else {
		print "output_object(): calling output_simple() instead of $func_name()\n";
		return $self->output_simple($obj, $embed);
	}
}

sub output_simple {
	my ($self, $obj) = @_;
	my $buf = '';
	$buf .= $obj->{text};
	return $buf;
}

sub error {
	my ($self, $msg) = @_;
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
	$self->{tree} = PuppetParser::Object->new(type => 'ROOT', level => -1);
	while($self->cur_token()) {
		$self->{tree}->add_child($self->scan_for_object($self->{tree}));
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
#		print "Type: " . $token->name . ", Text: " . $token->text . "\n";
#		print "Line: " . $self->{lexer}->line . "\n";
	}
	$self->{num_parsed_tokens} = scalar(@{$self->{parsed_tokens}});
	$self->{token_idx} = 0;
#	print "num_parsed_tokens=$num_parsed_tokens, token_idx=$token_idx\n";
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
#	print "cur_token(): token_idx=" . $self->{token_idx} . "\n";
	return defined($self->{parsed_tokens}->[$self->{token_idx}]) ? $self->{parsed_tokens}->[$self->{token_idx}] : undef;
}

sub next_token {
	my ($self) = @_;
	$self->{token_idx}++;
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

sub max_key_length {
	my ($self, $values) = @_;
	my $max_key_len = 0;
	for my $foo (@{$values}) {
		if(length($foo->{name}) > $max_key_len) {
			$max_key_len = length($foo->{name});
		}
	}
	return $max_key_len;
}

sub output_class {
	my ($self, $obj) = @_;
	my $buf = $self->indent() . 'class ' . $obj->{name} . ' {' . $self->newline(2);
	$self->{indent}++;
	for my $child (@{$obj->{contents}}) {
		$buf .= $self->output_object($child);
	}
	$buf .= "\n}\n";
	$self->{indent}--;
	return $buf;
}

sub parse_define {
	my ($self) = @_;
	my $obj = { type => 'define', args => [], contents => [] };
	$obj->{name} = $self->next_token()->{text};
	$self->next_token();
	while(my $token = $self->cur_token()) {
		if($token->{type} eq 'LBRACE') {
			$self->next_token();
			last;
		}
		if($token->{type} eq 'LPAREN') {
			# Beginning of arguments
			$self->next_token();
			next;
		}
		if($token->{type} eq 'RPAREN') {
			# End of arguments
			$self->next_token();
			next;
		}
		push @{$obj->{args}}, $self->parse_value(['COMMA', 'RPAREN']);
#		if($self->cur_token()->{type} eq 'RPAREN') {
#			$self->next_token();
#		}
		$self->next_token();
	}
	$self->add_to_parent($obj);
}

sub output_define {
	my ($self, $obj) = @_;
	my $buf = $self->indent() . 'define ' . $obj->{name};
		$buf .= '(';
	if(scalar(@{$obj->{args}})) {
		my @items;
		for my $foo (@{$obj->{args}}) {
			my $tmp = '';
			for (@{$foo}) {
				if($tmp ne '') {
					$tmp .= ' ';
				}
				$tmp .= $self->output_object($_);
			}
			push @items, $tmp;
		}
		$buf .= join(', ', @items);
	}
	$buf .= ')';
	$buf .= ' {' . $self->newline();
	$self->{indent}++;
	for my $child (@{$obj->{contents}}) {
		$buf .= $self->output_object($child);
	}
	$self->{indent}--;
	$buf .= "\n" . $self->indent() . '}' . "\n";
}

sub output_func_call {
	my ($self, $obj, $embed) = @_;
	my $buf = $embed ? '' : ($self->newline() . $self->indent());
	$buf .= $obj->{name} . '(';
	for my $arg (@{$obj->{args}}) {
		$buf .= $self->output_object($arg);
	}
	$buf .= ')' . ($embed ? '' : $self->newline());
	return $buf;
}

sub output_include {
	my ($self, $obj) = @_;
	return $self->indent() . 'include ' . $obj->{class} . $self->newline();
}

sub parse_hash {
	my ($self) = @_;
	my $obj = { type => 'hash', attribs => [] };
	$self->next_token(); # LBRACE
	while(my $token = $self->cur_token()) {
		if($token->{type} eq 'RETURN' || $token->{type} eq 'COMMENT') {
			$self->next_token();
			next;
		}
		if($self->cur_token()->{type} eq 'RBRACE') {
			last;
		}
		my $attr = { name => $token->{text} };
		$self->next_token(); # FARROW
		$self->next_token();
		$attr->{value} = $self->parse_value(['COMMA', 'SEMIC', 'RBRACE']);
		push @{$obj->{attribs}}, $attr;
		$self->next_token();
	}
	return $obj;
}

sub output_hash {
	my ($self, $obj) = @_;
	my $buf = '{' . "\n";
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
			$tmp .= $self->output_object($_);
		}
		$buf .= $tmp . ',' . "\n";
	}
	$self->{indent}--;
	$buf .= $self->indent() . '}' . "\n";
	return $buf;
}

sub parse_list {
	my ($self) = @_;
	my $obj = { type => 'list', contents => [] };
	my $tmpvalue;
	$self->next_token();
	while(my $token = $self->cur_token()) {
		if($token->{type} eq 'RETURN' || $token->{type} eq 'COMMENT') {
			$self->next_token();
			next;
		}
		if($token->{type} eq 'RBRACK') {
			$self->next_token();
			last;
		}
		push @{$obj->{contents}}, $self->parse_value(['COMMA', 'RBRACK']);
		if($self->cur_token()->{type} eq 'RBRACK') {
			$self->next_token();
			last;
		}
		$self->next_token();
	}
	return $obj;
}

sub output_list {
	my ($self, $obj, $embed) = @_;
#	print Dumper($obj);
	my $buf = '[';
	$self->{indent}++;
	my $numitems = scalar(@{$obj->{contents}});
	my $split = ($numitems > 4);
	my @items;
	for my $foo (@{$obj->{contents}}) {
		my $tmp = '';
		for (@{$foo}) {
			if($tmp ne '') {
				$tmp .= ' ';
			}
			$tmp .= $self->output_object($_);
		}
		push @items, $tmp;
	}
	$buf .= ($split ? $self->newline() . $self->indent() : '' ) . join(($split ? ',' . $self->newline() . $self->indent() : ', '), @items);
	$self->{indent}--;
	$buf .= ($split ? $self->newline() . $self->indent() : '') . ']';
	return $buf;
}

sub parse_value {
	# This function advances to the next token automatically
	my ($self, $until) = @_;
	if(!defined $until) {
		$until = ['RETURN'];
	}
	my $cur_token = $self->cur_token();
	if($cur_token->{type} eq 'LBRACE') {
		# Hash
		return [ $self->parse_hash() ];
	} elsif($cur_token->{type} eq 'LBRACK') {
		# List
		return [ $self->parse_list() ];
	} else {
		if($self->match_token_sequence(['DOLLAR_VAR', 'QMARK', 'LBRACE'])) {
			# This looks like a selector
			return [ $self->parse_selector() ];
		} else {
			# This is probably just an expression
			my $tmp = [];
			TOKEN: while(my $token = $self->cur_token()) {
				for(@{$until}) {
					if($token->{type} eq $_) {
						last TOKEN;
					}
				}
				push @{$tmp}, { type => uc($token->{type}), text => $token->{text} };
				$self->next_token();
			}
			return $tmp;
		}
	}
	print "Oh noes...we fell off the end!\n";
	print "parse_value(): type=" . $cur_token->{type} . ", text=" . $cur_token->{text} . "\n";
	return undef;
}

sub parse_var_assignment {
	my ($self) = @_;
	my $cur_token = $self->cur_token();
	my $obj = { type => 'var_assignment', name => $cur_token->{text}, value => undef };
	$self->next_token(); # equals sign
	$self->next_token();
	$obj->{value} = $self->parse_value();
	$self->add_to_parent($obj);
}

sub output_var_assignment {
	my ($self, $obj) = @_;
	my $buf = "\n";
	$buf .= $self->indent() . $obj->{name} . ' = ';
	for my $foo (@{$obj->{value}}) {
		$buf .= $self->output_object($foo);
	}
	return $buf;
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

sub parse_comment {
	my ($self) = @_;
	my $cur_token = $self->cur_token();
	$self->add_to_parent({ type => 'comment', value => $cur_token->{text} });
}

sub output_comment {
	my ($self, $obj, $embed) = @_;
	return $self->indent() . '# ' . $obj->{value} . $self->newline();
}

sub parse_resource {
	# Is this a resource definition or an override?
	my ($self) = @_;
	my @definition_patterns = (
		['NAME', 'LBRACE', 'SQUOTES', 'COLON'],
		['NAME', 'LBRACE', 'DQUOTES', 'COLON'],
		['NAME', 'LBRACE', 'DOLLAR_VAR', 'COLON'],
		['NAME', 'LBRACE', 'LBRACK'],
	);
	for my $pattern (@definition_patterns) {
		if($self->match_token_sequence($pattern)) {
			$self->parse_resource_definition();
			return;
		}
	}
	$self->parse_resource_defaults();
}

sub parse_resource_definition {
	my ($self) = @_;
	my @key_value_patterns = (
		['NAME', 'FARROW'],
		['DQUOTES', 'FARROW'],
		['SQUOTES', 'FARROW'],
	);
	my @res_title_patterns = (
		['DOLLAR_VAR', 'COLON'],
		['SQUOTES', 'COLON'],
		['DQUOTES', 'COLON'],
		['LBRACK'],
	);
	my $cur_token = $self->cur_token();
	my $restype = $cur_token->{text};
	$self->next_token(); # LBRACE
	RES: while(1) {
		my $obj = { type => 'resource_definition', restype => $restype, title => '', attribs => [] };
		while(my $token = $self->cur_token()) {
			if($token->{type} eq 'RETURN' || $token->{type} eq 'COMMENT') {
				$self->next_token();
				next;
			}
			# Is this a key => value pair?
			for my $pattern (@key_value_patterns) {
				if($self->match_token_sequence($pattern)) {
					# This is a key => value pair
					my $attr = { name => $token->{text} };
					$self->next_token(); # FARROW
					$self->next_token();
					$attr->{value} = $self->parse_value(['COMMA', 'SEMIC', 'RBRACE']);
					push @{$obj->{attribs}}, $attr;
					if($self->cur_token()->{type} eq 'RBRACE') {
						$self->add_to_parent($obj);
						last RES;
					}
				}
			}
			# Is this a resource title?
			for my $pattern (@res_title_patterns) {
				if($self->match_token_sequence($pattern)) {
					# This is a resource title
					if($obj->{'title'} eq '') {
						if($self->match_token_sequence(['DOLLAR_VAR', 'COLON'])) {
							$obj->{title} = [ $self->cur_token() ];
							$self->next_token();
						} else {
							$obj->{title} = $self->parse_value(['COLON']);
							#$self->next_token();
						}
						next;
					} else {
						$self->add_to_parent($obj);
						next RES;
					}
				}
			}
			if($self->cur_token()->{type} eq 'RBRACE') {
				$self->add_to_parent($obj);
				last RES;
			}
			# Looking for key => value pairs
			$self->next_token();
		}
	}
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

sub parse_resource_defaults {
	my ($self) = @_;
}

sub parse_resource_override {
	my ($self) = @_;
}

sub output_if {
	my ($self, $obj) = @_;
	my $buf = '';
	if($obj->{variant} eq 'if' || $obj->{variant} eq 'elsif') {
		$buf .= "\n" . $self->indent() . $obj->{variant} . ' ';
		for my $foo (@{$obj->{condition}}) {
			$buf .= $self->output_simple($foo) . ' ';
		}
	} elsif($obj->{variant} eq 'else') {
		$buf .= ' else';
	}
	$buf .= ' {' . "\n";
	$self->{indent}++;
	for my $child (@{$obj->{contents}}) {
		$buf .= $self->output_object($child);
	}
	$self->{indent}--;
	$buf .= "\n" . $self->indent() . '}';
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
				# The next token is of a type we want to ignore
				$cur_token = $self->next_token();
				next TYPE;
			}
		}
#		print "Looking for token of type: $type, Next is of type: " . $cur_token_type . ", value: " . $cur_token->{text} . "\n";
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
		$ignore = ['RETURN', 'COMMENT', 'MLCOMMENT'];
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
	print "Line: ", $token->{line}, ", ";
	print "Type: ", $token->{type}, ", ";
	print "Content:->", $token->{text}, "<-\n";
	my $orig_token = $self->get_token_idx();
	my $cur_token = undef;
	if($self->scan_for_token(['RETURN'], [])) {
		$self->next_token();
		return PuppetParser::Simple->new(parent => $parent, parser => $self);;
	}
	PACKAGE: for my $package (@object_classes) {
		PATTERN: for my $pattern (@{$package->patterns()}) {
			if($self->match_token_sequence($pattern, ['RETURN'])) {
				if($package->valid($self)) {
					return $package->new(parent => $parent, parser => $self);
				} else {
					next PACKAGE;
				}
			}
		}
	}
	$self->set_token_idx($orig_token);
	# We don't know how to handle this
	$self->error("Unexpected token '" . $self->cur_token()->{text} . "'");
}

sub scan_for_value {
	my ($self, $parent, $term) = @_;
	if(!defined $term) {
		$term = ['RETURN', 'COMMENT'];
	}
	my $orig_token = $self->get_token_idx();
	if($self->scan_for_token(['SQUOTES', 'NAME', 'DQUOTES', 'DOLLAR_VAR', 'NOT'])) {
		# This looks like a simple value
		my $value = PuppetParser::Simple->new(parser => $self);
		if(!$self->scan_for_token($term, [])) {
			# This isn't a simple value after all
			$self->set_token_idx($orig_token);
			return PuppetParser::Expression->new(parent => $parent, parser => $self, term => $term);
		}
		return $value;
	}
	if($self->scan_for_token(['LBRACE'])) {
		# This looks like a hash
		return PuppetParser::Hash->new(parent => $parent, parser => $self);
	}
	if($self->scan_for_token(['LBRACK'])) {
		# This looks like a list
		return PuppetParser::List->new(parent => $parent, parser => $self);
	}
	$self->error("Unexpected token '" . $self->cur_token()->{text} . "'");
}

package PuppetParser::Object;

use Data::Dumper;

our %defaults = (
	inner_spacing => 0,
	outer_spacing => 0,
);
our @patterns = ();

sub new {
	my ($class, %args) = @_;
	my $self = { contents => [] };
	bless($self, $class);
	for(keys %args) {
		$self->{$_} = $args{$_};
	}
	$self->apply_defaults();
	$self->parse();
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
		if(defined $self->{parent}) {
			if(!defined $self->{parent}->{level}) {
				print "apply_defaults(): parent=" . $self->{parent} . "\n";
			}
			$self->{level} = $self->parent()->{level} + 1;
		}
	}
}

sub dump {
	my ($self) = @_;
	my $d = Data::Dumper->new([$self], ['tree']);
	$d->Indent(4);
	$d->Seen({'*parser_purposely_filtered' => $self->{parser}});
	print $d->Dump;
}

sub parse {
	return;
}

sub parent {
	my ($self) = @_;
	return $self->{parent};
}

sub add_child {
	my ($self, $child) = @_;
	push @{$self->{contents}}, $child;
	if($self->{parser}->{debug}) {
		$self->dump();
	}
}

sub get_num_children {
	my ($self) = @_;
	return scalar(@{$self->{contents}});
}

sub get_child {
	my ($self, $idx) = @_;
	return $self->{contents}->[$idx];
}

sub get_prev_spacing {
	my ($self, $idx) = @_;
	my $obj;
	if($idx < 0) {
		$obj = $self;
	} else {
		$obj = $self->get_child($idx);
	}
	my $spacing = {};
	for (@{['inner_spacing', 'outer_spacing']}) {
		if(defined $obj->{$_}) {
			$spacing->{$_} = $obj->{$_};
		}
	}
	return $spacing;
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

sub valid {
	return 1;
}

sub output {
	my ($self) = @_;
	return $self->output_children();
}

sub output_children {
	my ($self) = @_;
	my $buf = '';
	for(@{$self->{contents}}) {
		$buf .= $_->output();
	}
	return $buf;
}

sub format_output {
	my ($self, $output) = @_;
#	my $prev_spacing = $self->get_prev_spacing();
	# Fix this
	return "\n\n" . $output . "\n\n";
}

package PuppetParser::Simple;

our @ISA = 'PuppetParser::Object';
our @patterns = (
	['NAME'],
	['DOLLAR_VAR'],
	['DQUOTES'],
	['SQUOTES'],
);

sub patterns {
	return \@patterns;
}

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

package PuppetParser::Comment;

our @ISA = 'PuppetParser::Object';
our @patterns = (
	['COMMENT'],
);

sub patterns {
	return \@patterns;
}

sub parse {
	my ($self) = @_;
	my $token = $self->{parser}->cur_token();
	$self->{comment} = $token->{text};
	$self->{comment} =~ s/^[# ]+//;
	$self->{parser}->next_token();
}

sub output {
	my ($self) = @_;
	return $self->indent() . '# ' . $self->{comment} . $self->nl();
}

package PuppetParser::List;

our @ISA = 'PuppetParser::Object';

sub apply_defaults {
	my ($self) = @_;
	$self->SUPER::apply_defaults({ start => 'LBRACK', end => 'RBRACK' });
}

sub parse {
	my ($self) = @_;
	$self->{items} = [];
	if(!$self->{parser}->scan_for_token([$self->{start}], [])) {
		# The sky is falling
		$self->{parser}->error("Did not find expected token '" . $self->{start} . "'");
	}
	$self->{parser}->next_token();
	while(1) {
		if($self->{parser}->scan_for_token([$self->{end}], [])) {
			$self->{parser}->next_token();
			last;
		}
		if($self->{parser}->scan_for_token(['COMMA', 'RETURN'], [])) {
			$self->{parser}->next_token();
			next;
		}
		if($self->{parser}->scan_for_token(['COMMENT'], [])) {
			push @{$self->{items}}, PuppetParser::Comment->new(parent => $self, parser => $self->{parser});
		}
		push @{$self->{items}}, $self->{parser}->scan_for_value($self, ['COMMA', $self->{end}]);
	}
}

package PuppetParser::Hash;

our @ISA = 'PuppetParser::Object';

sub parse {
	my ($self) = @_;
	$self->{parser}->next_token();
	$self->{items} = [];
	while(1) {
		if($self->{parser}->scan_for_token(['COMMA', 'RETURN'], [])) {
			$self->{parser}->next_token();
			next;
		}
		if($self->{parser}->scan_for_token(['RBRACE'], [])) {
			$self->{parser}->next_token();
			last;
		}
		if($self->{parser}->scan_for_token(['COMMENT'], [])) {
			push @{$self->{items}}, PuppetParser::Comment->new(parent => $self, parser => $self->{parser});
			next;
		}
		if(PuppetParser::KeyValuePair->valid($self->{parser})) {
			push @{$self->{items}}, PuppetParser::KeyValuePair->new(parent => $self, parser => $self->{parser});
			next;
		}
		$self->{parser}->error("Unexpected token '" . $self->{parser}->cur_token()->{text} . "'");
	}
}

package PuppetParser::Expression;

our @ISA = 'PuppetParser::Object';

sub parse {
	my ($self) = @_;
	$self->{parts} = [];
	while(1) {
		if($self->{parser}->scan_for_token($self->{term}, [])) {
			last;
		}
		if(PuppetParser::FunctionCall->valid($self->{parser})) {
			push @{$self->{parts}}, PuppetParser::FunctionCall->new(parent => $self, parser => $self->{parser}, embed => 1);
			next;
		}
		push @{$self->{parts}}, PuppetParser::Simple->new(parent => $self, parser => $self->{parser});
	}
}

sub output {
	my ($self) = @_;
	my $buf = join(' ', map { $_->output() } @{$self->{parts}});
	return $buf;
}

package PuppetParser::KeyValuePair;

our @ISA = 'PuppetParser::Object';

sub valid {
	my ($class, $parser) = @_;
	my $orig_token = $parser->get_token_idx();
	if($parser->scan_for_token(['NAME', 'SQUOTES', 'DQUOTES'], [])) {
		$parser->next_token();
		if($parser->scan_for_token(['FARROW'], [])) {
			$parser->set_token_idx($orig_token);
			return 1;
		}
	}
	return 0;
}

sub parse {
	my ($self) = @_;
	$self->{key} = PuppetParser::Simple->new(parent => $self, parser => $self->{parser});
	$self->{parser}->next_token();
	$self->{value} = $self->{parser}->scan_for_value($self, ['COMMA', 'SEMIC', 'RETURN', 'RBRACE']);
}

package PuppetParser::Class;

use Data::Dumper;

our @ISA = 'PuppetParser::Object';
our %defaults = (
	inner_spacing => 1,
	outer_spacing => 1,
);
our @patterns = (
	['CLASS'],
);

sub parse {
	my ($self) = @_;
	$self->{parser}->next_token();
	if(!$self->{parser}->scan_for_token(['NAME'])) {
		$self->{parser}->error("Did not find expected token type after 'class'");
	}
	$self->{classname} = PuppetParser::Simple->new(parent => $self, parser => $self->{parser});
	if(!$self->{parser}->scan_for_token(['LBRACE'])) {
		$self->{parser}->error("Did not find expected token '{'");
	}
	$self->{parser}->next_token();
	while(1) {
		if($self->{parser}->scan_for_token(['RBRACE'])) {
			$self->{parser}->next_token();
			last;
		}
		if($self->{parser}->eof()) {
			$self->{parser}->error("Unexpected end of file");
		}
		$self->add_child($self->{parser}->scan_for_object($self));
	}
}

sub patterns {
	return \@patterns;
}

sub output {
	my ($self) = @_;
	my $buf = $self->indent() . 'class ' . $self->{classname}->output() . ' {' . $self->nl();
	$buf .= $self->output_children();
	$buf .= '}' . $self->nl();
	return $buf;
}

package PuppetParser::Define;

our @ISA = 'PuppetParser::Object';
our @patterns = (
	['DEFINE'],
);

sub patterns {
	return \@patterns;
}

sub parse {
	my ($self) = @_;
	$self->{parser}->next_token();
	if(!$self->{parser}->scan_for_token(['NAME'], [])) {
		$self->{parser}->error("Unexpected token after 'define'");
	}
	$self->{defname} = PuppetParser::Simple->new(parent => $self, parser => $self->{parser});
	$self->{args} = [];
	if($self->{parser}->scan_for_token(['LPAREN'])) {
		$self->{parser}->next_token();
		while(1) {
			if($self->{parser}->scan_for_token(['RPAREN'], [])) {
				$self->{parser}->next_token();
				last;
			}
			if($self->{parser}->scan_for_token(['COMMA'], [])) {
				$self->{parser}->next_token();
				next;
			}
			push @{$self->{args}}, $self->{parser}->scan_for_value($self, ['COMMA', 'RPAREN']);
		}
	}
	if(!$self->{parser}->scan_for_token(['LBRACE'], [])) {
		$self->{parser}->error("Unexpected token");
	}
	$self->{parser}->next_token();
	while(1) {
		if($self->{parser}->scan_for_token(['RBRACE'])) {
			$self->{parser}->next_token();
			last;
		}
		if($self->{parser}->eof()) {
			$self->{parser}->error("Unexpected end of file");
		}
		$self->add_child($self->{parser}->scan_for_object($self));
	}
}

package PuppetParser::FunctionCall;

our @ISA = 'PuppetParser::Object';
our @patterns = (
	['NAME', 'LPAREN'],
);

sub patterns {
	return \@patterns;
}

sub valid {
	my ($class, $parser) = @_;
	if($parser->match_token_sequence(['NAME', 'LPAREN'], [])) {
		return 1;
	}
	return 0;
}

sub parse {
	my ($self) = @_;
	$self->{funcname} = PuppetParser::Simple->new(parent => $self, parser => $self->{parser});
	if(!$self->{parser}->scan_for_token(['LPAREN'])) {
		$self->{parser}->error("Did not find expected token '('");
	}
	$self->{parser}->next_token();
	$self->{args} = [];
	while(1) {
		if($self->{parser}->scan_for_token(['RPAREN'])) {
			$self->{parser}->next_token();
			last;
		}
		push @{$self->{args}}, $self->{parser}->scan_for_value($self, ['COMMA', 'RPAREN']);
	}
}

sub output {
	my ($self) = @_;
	my $buf = ($self->{embed} ? '' : $self->indent()) . $self->{funcname}->output() . '(';
	for(@{$self->{args}}) {
		$buf .= $_->output();
	}
	$buf =~ s/, $//;
	$buf .= ')' . ($self->{embed} ? '' : $self->nl());
	return $buf;
}

package PuppetParser::IfStatement;

our @ISA = 'PuppetParser::Object';
our @patterns = (
	['IF'],
	['ELSIF'],
	['ELSE'],
);

sub patterns {
	return \@patterns;
}

sub parse {
	my ($self) = @_;
	$self->{variant} = PuppetParser::Simple->new(parent => $self, parser => $self->{parser});
	if(!$self->{parser}->scan_for_token(['LBRACE'], [])) {
		$self->{condition} = $self->{parser}->scan_for_value($self, ['LBRACE']);
	}
	$self->{parser}->next_token();
	while(1) {
		if($self->{parser}->scan_for_token(['RBRACE'])) {
			$self->{parser}->next_token();
			last;
		}
		if($self->{parser}->eof()) {
			$self->{parser}->error("Unexpected end of file");
		}
		$self->add_child($self->{parser}->scan_for_object($self));
	}
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
our @patterns = (
	['INCLUDE'],
);

sub patterns {
	return \@patterns;
}

sub parse {
	my ($self) = @_;
	$self->{parser}->next_token();
	if(!$self->{parser}->scan_for_token(['NAME', 'DOLLAR_VAR'])) {
		$self->{parser}->error("Did not find expected token after 'include'");
	}
	$self->{class} = PuppetParser::Simple->new(parent => $self, parser => $self->{parser});
}

sub output {
	my ($self) = @_;
	return $self->indent() . 'include ' . $self->{class}->output() . $self->nl();
}

package PuppetParser::VarAssignment;

our @ISA = 'PuppetParser::Object';
our @patterns = (
	['DOLLAR_VAR', 'EQUALS'],
);

sub patterns {
	return \@patterns;
}

sub parse {
	my ($self) = @_;
	$self->{varname} = PuppetParser::Simple->new(parent => $self, parser => $self->{parser});
	if(!$self->{parser}->scan_for_token(['EQUALS'])) {
		$self->{parser}->error("Did not find expected token '=' after '" . $self->{varname}->{text} . "'");
	}
	$self->{parser}->next_token();
	$self->{value} = [];
	$self->{value} = $self->{parser}->scan_for_value($self, ['RETURN']);
}

package PuppetParser::Resource;

our @ISA = 'PuppetParser::Object';
our @patterns = (
	['NAME', 'LBRACE'],
);
our @key_value_patterns = (
	['NAME', 'FARROW'],
	['DQUOTES', 'FARROW'],
	['SQUOTES', 'FARROW'],
);
our @res_title_patterns = (
	['DOLLAR_VAR', 'COLON'],
	['SQUOTES', 'COLON'],
	['DQUOTES', 'COLON'],
	['LBRACK'],
);

sub patterns {
	return \@patterns;
}

sub parse {
	my ($self) = @_;
	$self->{restype} = PuppetParser::Simple->new(parent => $self, parser => $self->{parser});
	if(!$self->{parser}->scan_for_token(['LBRACE'])) {
		$self->{parser}->error("Did not find expected token '{'");
	}
	$self->{parser}->next_token();
	TOKEN: while(1) {
		if($self->{parser}->scan_for_token(['RBRACE'])) {
			$self->{parser}->next_token();
			last TOKEN;
		}
		if($self->{parser}->scan_for_token(['RETURN'], [])) {
			# Skip a newline
			$self->{parser}->next_token();
			next TOKEN;
		}
		if($self->{parser}->scan_for_token(['COMMENT'], ['RETURN'])) {
			# I don't know what to do with this yet, but we're looking for it anyway
			$self->{parser}->next_token();
			next TOKEN;
		}
		if($self->{parser}->scan_for_token(['COMMA'])) {
			$self->{parser}->next_token();
			next TOKEN;
		}
		for my $pattern (@res_title_patterns) {
			if($self->{parser}->match_token_sequence($pattern)) {
				# It's a resource title
				$self->{restitle} = $self->{parser}->scan_for_value($self, ['COLON']);
				$self->{parser}->next_token();
				next TOKEN;
			}
		}
		for my $pattern (@key_value_patterns) {
			if($self->{parser}->match_token_sequence($pattern)) {
				# It's a key/value pair
				my $key = PuppetParser::Simple->new(parent => $self, parser => $self->{parser});
				$self->{parser}->next_token();
				# Parse the value
				$self->{value} = $self->{parser}->scan_for_value($self, ['COMMA', 'SEMIC', 'RETURN', 'RBRACE']);
				next TOKEN;
			}
		}
		$self->{parser}->error("Unexpected token '" . $self->{parser}->cur_token()->{text} . "'");
	}
}

package main;

$| = 1;

use Getopt::Std;

# Flags
my %options;
my $output = '';
my $json = 0;
my $debug = 0;

# Parse options
my $result = getopts('jdo:', \%options);
if(defined $options{'o'}) {
	$output = $options{'o'};
}
if(defined $options{'j'}) {
	$json = $options{'j'};
}
if(defined $options{'d'}) {
	$debug = $options{'d'};
}
my $file = shift;

print "Parsing $file\n";
my $parser = PuppetParser->new(file => $file, debug => $debug);
$parser->parse();

if($json) {
	$parser->output_json($output);
} else {
	$parser->output($output);
}
