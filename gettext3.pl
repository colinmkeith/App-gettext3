#!/usr/bin/env perl

# use Modern::Perl '2012';

use Data::Printer;
$debug = $ARGV[0] eq '-d' ? shift(@ARGV) : 0;

for my $file (@ARGV) {
  if($file =~ m/\.tmpl$/) {
    parseTemplateToolkit($file);
  } elsif($file =~ m/\.pl$/) {
    parsePerl($file);
  }
}

# {{{ parseTemplateToolkit($file)
sub parseTemplateToolkit {
  require Template;
  require Template::Parser;

  my($file) = @_;
  open(my $DATA, '<', $file) || die "Error parsing template: $file: $!\n";
  my $data = join('', <$DATA>);
  close($DATA);

  my $p = Template::Parser->new();
  my $r = $p->split_text($data) || die $p->error();

  for (my $k = 0; $k < @{$r}; $k++) {
    my $text = $r->[$k];
    if($text eq 'TEXT') {
      $k++;

      #       $text = $r->[$k];
      #       my $nlCount = ($text =~ tr/\n//);
      #       $nlCount && warn "Adding $nlCount, $text";
      #       $nlCount && ($addLine += $nlCount);
      next;
    } elsif(ref($text)) {
      ($text, $line, $tokens, $msgType) = @{$text};
      @tokens = @{$tokens};

      $line =~ m/^([0-9]+)(?:-([0-9]+))?$/;
      my($startLine) = ($1, $2);

      # my($startLine, $endLine) = ($1, $2);

      # {{{ Parse Tokens:
      for (my $i = 0; $i < @tokens; $i += 2) {
        my($type, $toke) = @tokens[$i, $i + 1];

        my @ret;

        # nested arrays;
        if(ref($type)) {
          splice(@tokens, $i, 1, 'IDENT', $type->[0]);
          next;
        }

        elsif($type eq 'NL') {
          $startLine++;
        }

        # {{{ IDENT __X()
        elsif($type eq 'IDENT' && $toke =~ m/^N?__[xnp]*$/) {
          my $j;
          my $parenCount = 0;

          my $isMultiPart = $toke =~ m/^N?__[npx]+$/;
          my $isPlural    = $toke =~ m/^N?__(?:n|nx|xn|np|npx)$/;

          my @mPart;
          my $invalidKey;

          for ($j = $i + 2; $j < @tokens; $j += 2) {
            my($type, $toke) = @tokens[$j, $j + 1];

            # nested arrays;
            if(ref($type)) {
              splice(@tokens, $j, 1, 'IDENT', $type->[0]);
            }

            elsif($type eq '(') {
              $parenCount++;
            }

            elsif($type eq ')') {
              $parenCount--;
              if(!$parenCount) {
                if(!defined($mPart[1])) {
                  $mPart[1] = $j;
                } elsif($isPlural && !defined($mPart[3])) {
                  $mPart[3] = $j;
                }
                last;
              }
            }

            # {{{ First (or second) Text/literal block
            elsif($type eq 'LITERAL' || $type eq 'TEXT' || $type eq '"') {
              $endLine += ($toke =~ tr/\n//);
              if(!defined($mPart[0])) {
                $mPart[0] = $j;
              } elsif($isPlural && !defined($mPart[2])) {
                $mPart[2] = $j;
              }
            }    # }}}

            # {{{ Comma type
            elsif($type eq 'COMMA') {
              if(!defined($mPart[1])) {
                $mPart[1] = $j;
              } elsif($isPlural && !defined($mPart[3])) {
                $mPart[3] = $j;
              }
            }    # }}}

            elsif($type eq 'NL') {
              $endLine++;
            }

            elsif($type eq 'IDENT') {
              $invalidKey = 1;
            }

          }

          $j += 2;

          my $comment = extractStringFromTemplate($i, $j, \@tokens);
          $comment = cleanupQuotedString($comment);

          $invalidKey && next;
          my $msgstr1 =
           extractStringFromTemplate($mPart[0], $mPart[1] || $j, \@tokens);
          $msgstr1 = cleanupQuotedString($msgstr1);

          my @textLines = split(/\n/, $text);
          while(my $text = +shift(@textLines)) {
            if($text =~ m/^.*?(N?__)/) {
              unshift(@textLines, $text);
              last;
            }
          }

          #           if($textLines[0] =~ s/^N?__[nxp]*\(//) {
          #             while(my $text = shift(@textLines)) {
          #               chomp($text);
          #               $text =~ s/\\["']//g;
          #               $text =~ s/'[^']*'//g;
          #               $text =~ s/"[^"]*"//g;
          #               index($text, ')') != -1 && last;
          #             }
          #           }

          $line = $startLine;
          $endLine += $startLine;
          $endLine && $endLine != $startLine && ($line .= '-' . $endLine);
          $endLine = 0;

          my $ret = ["#. $comment", "#: $file:$line"];
          push(@{$ret}, qq/msgid "$msgstr1"/);

          if($isPlural) {
            my $msgstr2 =
             extractStringFromTemplate($mPart[2], $mPart[3] || $j, \@tokens);
            $msgstr1 = cleanupQuotedString($msgstr2);
            push(
              @{$ret},
              qq/msgid_plural "$msgstr2"/,
              qq/msgstr[0] "$msgstr1"/,
              qq/msgstr[1] "$msgstr2"/
            );
          } else {
            push(@{$ret}, qq/msgstr "$msgstr1"/);
          }

          printGetTextBlocks($ret);
        }    # }}}

        else {

          # warn "$type, ${toke}\n";
        }
      }    # }}}
    }

  }
}    # }}}

# {{{ extractStringFromTemplate($start, $stop, $tokens, [$nocat])
sub extractStringFromTemplate {
  my($start, $stop, $tokens, $nocat) = @_;
  my @tokens = @{$tokens}[$start .. $stop];

  # {{{ Handle TEXT=> LITERAL and CAT ("xxx" _ "yyyy")
  for (my $x = 0; $x < @tokens; $x += 2) {
    if($tokens[$x] eq 'LITERAL') {
      $tokens[$x + 1] =~ s/^'(.*)'$/$1/s;
      $tokens[$x + 1] =~ s/\\\\'/'/sg;
      $tokens[$x + 1] =~ s/\\\\"/"/sg;
      $tokens[$x + 1] = "'$tokens[$x+1]'";
    } elsif($tokens[$x] eq '"'
      && $x < @tokens - 4
      && $tokens[$x + 2] eq 'TEXT'
      && $tokens[$x + 4] eq '"') {
      my $newText = $tokens[$x + 3];
      $newText =~ s/\\\\'/'/sg;
      $newText =~ s/\\\\"/"/sg;
      $newText =~ s/'/\\'/sg;

      splice(@tokens, $x, 6, 'LITERAL', "'$newText'");
    }
  }    # }}}

  # {{{ Handle CAT ("xxx" _ "yyyy")
  if(@tokens > 5) {
    for (my $x = 0; $x < @tokens; $x += 2) {
      if($tokens[$x] eq 'CAT') {
        $x > 1 || next;
        $x < $#tokens - 2 || next;
        my($ptype, $pdata, $ntype, $ndata) =
         @tokens[$x - 2, $x - 1, $x + 2, $x + 3];

        if($ptype eq 'LITERAL') {
          $pdata =~ s/^'(.*)'/$1/;
        }

        if($ntype eq 'LITERAL') {
          $ndata =~ s/^'(.*)'/$1/;
        }

        if(  ($ptype eq 'LITERAL' || $ptype eq 'TEXT')
          && ($ntype eq 'LITERAL' || $ntype eq 'TEXT')) {
          splice(@tokens, $x - 2, 6, 'LITERAL', "'$pdata$ndata'");
        }
      }
    }
  }    # }}}

  for (my $x = 0; $x < @tokens; $x += 2) {
    if($tokens[$x] eq 'LITERAL') {
      $tokens[$x + 1] =~ s/^'(.*)'$/$1/s;
      $tokens[$x + 1] =~ s/\\\\'/'/sg;
      $tokens[$x + 1] =~ s/\\\\"/"/sg;
      $tokens[$x + 1] =~ s/"/\\"/sg;
      $tokens[$x + 1] = "'$tokens[$x+1]'";
    }
  }

  # To give us every other element, e.g. for($i=0;$i<@tokens;$i+=2)
  my $flipflop;

  my $str = join('',
    grep {$_}
    map { ($flipflop++ % 2) ? ($_ eq ',' ? "$_ " : $_) : undef }
    grep { !ref($_) } @tokens);

  # $str = cleanupQuotedString($str);
  # $str =~ s/^(N?__[npx]*\()\\"(.*)\\",/$1"$2",/;
  return $str;
}    # }}}

# {{{ parsePerl()
sub parsePerl {
  require PPI;
  my($file)    = @_;
  my $Document = PPI::Document->new($file);
  my $wordList = $Document->find('PPI::Token::Word');
  while(my $ppiWord = +shift(@{$wordList})) {
    my $fname = $ppiWord->content();
    my $ret = processPPIToken($file, $fname, $ppiWord);
    if($ret && @{$ret}) {
      printGetTextBlocks($ret);
    }
  }
}    # }}}

# {{{ processPPIToken($file, $msgType, $ppiWord);
sub processPPIToken {
  my($file, $msgType, $ppiWord) = @_;

  if($msgType !~ m/^N?__[nxp]*$/ && $msgType ne 'pagedisplay') {
    return;
  }

  my $comment = $ppiWord->parent->content();
  my $lineDiff = ($comment =~ tr/\n//);
  $comment =~ s/\n//mg;
  my $line = $ppiWord->parent->line_number();
  if($lineDiff) {
    $line .= '-' . ($line + $lineDiff);
  }

  my($msgstr1, $msgstr2);
  my $sib = $ppiWord->next_token();

  # {{{ if($msgType eq 'pagedisplay')
  if($msgType eq 'pagedisplay') {
    my $pageName = getNextStringToken(\$sib);

    if(!$pageName) {
      warn
       "Found pagedisplay() call to $pageName, but did not find msg name parameter @ $file:$line : $comment\n";
      return;
    }

    $pageName =~ m/(success_messages|error_message).tmpl['"]$/ || return;

    $msgstr1 = cleanupQuotedString(getNextStringToken(\$sib));

    # If the next parameter name ends with _multiple
    # then we will call __nx() so need msgid_plural
    $msgstr2 = cleanupQuotedString(getNextStringToken(\$sib));
    $msgstr2 =~ m/_multiple$/ || undef $msgstr2;
  }    # }}}

  # {{{ __(), __x(), N__(), N__x() single strings
  elsif($msgType =~ m/^N?__x?$/) {
    $msgstr1 = cleanupQuotedString(getNextStringToken(\$sib));

    # Not followed by a quoted string so not valid
    $msgstr1 || return;
  }    # }}}

  # {{{ else multpart ids
  else {
    $msgstr1 = cleanupQuotedString(getNextStringToken(\$sib));
    $msgstr1 || return;
    $sib     = $sib->next_token();
    $msgstr2 = cleanupQuotedString(getNextStringToken(\$sib));
  }    # }}}

  my $ret = ['#. ' . $comment, "#: $file:$line"];

  push(@{$ret}, qq/msgid "$msgstr1"/);
  if($msgstr2) {
    push(
      @{$ret},
      qq/msgid_plural "$msgstr2"/,
      qq/msgstr[0] "$msgstr1"/,
      qq/msgstr[1] "$msgstr2"/
    );
  } else {
    push(@{$ret}, qq/msgstr "$msgstr1"/);
  }

  return $ret;
}    # }}}

# {{{ getNextStringToken($sib);
sub getNextStringToken {
  my $sib = ${$_[0]};
  while($sib && !$sib->isa('PPI::Token::Quote')) {
    $sib->isa('PPI::Token::Structure') && $sib->content() eq ';' && last;
    $sib = $sib->next_token();
  }

  $_[0] = \$sib;

  if($sib && $sib->isa('PPI::Token::Quote')) {
    return cleanupQuotedString($sib->content());
  }

  return '';
}    # }}}

# {{{ cleanupQuotedString($str)
sub cleanupQuotedString {
  my($str) = @_;
  $str =~ s/^(['"#])//;
  $str =~ s/$1$//;
  $str =~ s/\\//mg;
  $str =~ s/^(.*N?__[nxp]*\("[^"]+)"/$1\\"/sg || $str =~ s/"/\\"/mg;
  $str =~ s/\n/\\n/sg;
  return $str;
}    # }}}

sub printGetTextBlocks {
  print join("\n", @{$_[0]}, '', '');
}

1;

