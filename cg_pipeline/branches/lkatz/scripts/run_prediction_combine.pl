#!/usr/bin/env perl

# run-prediction-combine: Combine gene predictions
# Author: Lee Katz (lkatz@cdc.gov)

# TODO: investigate integration of Genomix, Jigsaw, etc.

package PipelineRunner;
my ($VERSION) = ('$Id: $' =~ /,v\s+(\d+\S+)/o);

my $settings = {
  appname => 'cgpipeline',
};
my $stats;

use strict;
use FindBin;
use lib "$FindBin::RealBin/../lib";
$ENV{PATH} = "$FindBin::RealBin:".$ENV{PATH};
use AKUtils qw(logmsg);
use CGPipelineUtils;

use Getopt::Long;
use File::Temp ('tempdir');
use File::Path;
use File::Spec;
use File::Copy;
use File::Basename;
use List::Util qw(min max sum shuffle);
use Bio::Seq;
use Bio::SeqIO;
use Bio::SeqFeature::Generic;
use Bio::Species;
use Bio::Annotation::SimpleValue;
use AKUtils;
use CGPipeline::TagFactory;
use Data::Dumper;

$0 = fileparse($0);
local $SIG{'__DIE__'} = sub { my $e = $_[0]; $e =~ s/(at [^\s]+? line \d+\.$)/\nStopped $1/; die("$0: ".(caller(1))[3].": ".$e); };
sub logmsg {my $FH = $PipelineRunner::LOG || *STDOUT; print $FH "$0: ".(caller(1))[3].": @_\n";}

exit(main());

sub main() {
  $settings = AKUtils::loadConfig($settings);

  die(usage()) if @ARGV < 1;

  my @cmd_options = ('tempdir=s','ChangeDir=s', 'keep', 'outfile=s', 'min_predictors_to_call_orf=i');
  GetOptions($settings, @cmd_options) or die;
  
  $$settings{outfile} ||= "$0.out.gff";
  $$settings{min_predictors_to_call_orf}||=1; 

  my @input_files = @ARGV;

  foreach my $file (@input_files, @ref_files) {
    $file = File::Spec->rel2abs($file);
    die("Input or reference file $file not found") unless -f $file;
  }

  $$settings{tempdir} ||= tempdir($$settings{tempdir} or File::Spec->tmpdir()."/$0.$$.XXXXX", CLEANUP => !($$settings{keep}));
  $$settings{tempdir} = File::Spec->rel2abs($$settings{tempdir});
  mkdir $$settings{tempdir} if(!-d $$settings{tempdir});
  logmsg "Temporary directory is $$settings{tempdir}";

  my $predictions = getGenePredictions(\@input_files, $settings);

  return 0;
}

sub getGenePredictions($$$$$) {
  my ($input_files, $settings) = @_;

  my (%all_predictions, %unified_predictions);
  my @minority_rep_orfs;

  for my $file(@$input_files){
    my $pred_set={};
    my $pred_type=guessPredType($file,$settings);
    if($pred_type eq 'genemark'){
      $pred=getGeneMarkResults($file,$settings);
    } elsif($pred_type eq 'glimmer'){
      $pred=getGlimmerResults($file,$settings);
    } elsif($pred_type eq 'gff3'){
      $pred=getGff3Results($file,$settings);
    } else{
      die "ERROR: I did not know how to interpret $file. I guessed the format as $pred_type";
    }
    foreach my $seq(keys %$pred_set){
      foreach my $pred (@{$$pred_set{$seq}}) {
        push(@{$all_predictions{$seq}->{$$pred{strand}}->{$$pred{stop}}},$pred);
      }
    }
  }
  
  # Categorize and reconcile predictions
  my $numAbnormalTranslations=0;
  foreach my $seq (sort AKUtils::alnum keys %all_predictions) {
    foreach my $strand (keys %{$all_predictions{$seq}}) {
      foreach my $stop (keys %{$all_predictions{$seq}->{$strand}}) {
        my $contrib_predictions = $all_predictions{$seq}->{$strand}->{$stop};
        if (scalar(@$contrib_predictions) < $$settings{min_predictors_to_call_orf}) {
          push(@minority_rep_orfs, @$contrib_predictions); next;
        }
        my %starts;

        foreach my $pred (@$contrib_predictions) {
          $starts{$$pred{predictor}} = $$pred{start};
        }
        my $best_start;
        if ($contrib_predictions->[0]->{strand} eq '+') {
          # Choose the least trivial (most downstream) predicted start.
          $best_start = max($starts{gmhmmp}, $starts{Glimmer3});

          if (defined $starts{BLAST} and $starts{BLAST} < $best_start) {
            # BLAST alignment extends upstream of the predicted start, so find the closest Met to the start predicted by BLAST.
            # warn "BLAST alignment upstream of predicted start (+)\n";
          }
        } else {
          $starts{gmhmmp} ||= 1e999; $starts{Glimmer3} ||= 1e999;
          $best_start = min($starts{gmhmmp}, $starts{Glimmer3});
#          die("Internal error") if $best_start == 1e999;
          if (defined $starts{BLAST} and $starts{BLAST} > $best_start) {
            # BLAST alignment extends upstream of the predicted start, so find the closest Met to the start predicted by BLAST.
            # warn "BLAST alignment upstream of predicted start (-)\n";
          }
#          $best_start = length($$input_seqs{$seq}) if $best_start > length($$input_seqs{$seq}) - 3; # FIXME: signal truncated predicts
        }
        my %prediction;
        foreach my $contrib_pred (@$contrib_predictions) {
          $prediction{$_} = $$contrib_pred{$_} for keys %$contrib_pred;
        }
        $prediction{start} = $best_start;
        ($prediction{strand} eq '+' ? $prediction{lo} : $prediction{hi}) = $best_start;
        $prediction{predictor} = [];
        push(@{$prediction{predictor}}, $$_{predictor}) for @$contrib_predictions;
        
        $unified_predictions{$seq}->{$strand}->{$stop} = \%prediction;

        my $nt_seq = substr($$input_seqs{$seq}, min($best_start, $stop)-1, abs($best_start - $stop)+1);
        if ($contrib_predictions->[0]->{strand} eq '-') {
          $nt_seq = reverse($nt_seq); $nt_seq =~ tr/ATGC/TACG/;
        }
        my $aa_seq = AKUtils::dna2aa($nt_seq);

        # NB: longest known protein in e. coli is 1538 aa
        # TODO put these settings into conf file
        $$settings{prediction_minLength}||=30;
        $$settings{prediction_maxLength}||=2000;
        if (length($aa_seq) < $$settings{prediction_minLength} or length($aa_seq) > $$settings{prediction_maxLength} or $aa_seq !~ /M.+\*$/) {
          warn("WARNING: abnormal translated sequence (either too long, too short, or doesn't have a possible M start site): \n\t$nt_seq\n\t$aa_seq\n");
          $numAbnormalTranslations++;
        }

      }
    }
  }
  logmsg "SUMMARY: There were $numAbnormalTranslations abnormal translations";

  if ($$settings{prediction_print_minority_reports}) {
    open(MR, '>', "$$settings{outfile}.minority_reports.log")
      or die("Unable to open file $$settings{outfile}.minority_reports.log for writing: $!");
    # print MR "Minority reports:\n";
    print MR "$$_{seqname}:$$_{start}..$$_{stop} ($$_{strand}) [L=".abs($$_{start}-$$_{stop})."] [P=$$_{predictor}]\n"
      for sort {$$a{seqname} cmp $$b{seqname}} @minority_rep_orfs;
    close MR;
  }

  return \%unified_predictions;
}

sub generateGenBankFile($$$) {
  my ($seqs, $predictions, $settings) = @_;
  die("Internal error: no strain name supplied") unless defined $$settings{strain_name};
  die("Internal error: no classification supplied") unless defined $$settings{classification};
  die("Internal error: no output filename supplied") unless defined $$settings{outfile};

  $$settings{division} ||= 'BCT';

  my $gb_out_h = Bio::SeqIO->new(-file => '>'.$$settings{outfile}, -format => 'genbank');
  my $species_obj = Bio::Species->new(-classification => $$settings{classification},
    -sub_species => $$settings{strain_name},
  );

  $$settings{tag_prefix} ||= $$settings{strain_name}."_";
  my $cds_tag_factory = CGPipeline::TagFactory->new({factory_type => "draft_orf_tagger",
    strain_name => $$settings{strain_name},
    tag_prefix => $$settings{tag_prefix}});
  my $trna_tag_factory = CGPipeline::TagFactory->new({factory_type => "draft_orf_tagger",
    strain_name => $$settings{strain_name},
    tag_prefix => $$settings{tag_prefix}.'t'});
  my $rrna_tag_factory = CGPipeline::TagFactory->new({factory_type => "draft_orf_tagger",
    strain_name => $$settings{strain_name},
    tag_prefix => $$settings{tag_prefix}.'r'});
  my $crispr_tag_factory = CGPipeline::TagFactory->new({factory_type => "draft_orf_tagger",
    strain_name => $$settings{strain_name},
    tag_prefix => $$settings{tag_prefix}.'c'});

  foreach my $seqname (sort keys %$seqs) {
    my $gb_seqname = $seqname; $gb_seqname =~ s/\s+/_/g;
    my $gbseq = Bio::Seq::RichSeq->new(-seq => $$seqs{$seqname},
      -id  => $gb_seqname,
      -desc => " $$settings{strain_name}, unfinished sequence, whole genome shotgun sequence",
      -keywords => ['WGS'],
      -species => $species_obj,
      -division => $$settings{division},
    );
    # each contig needs a source tag
    my $sourceFeature=new Bio::SeqFeature::Generic(-primary_tag=>'source',
      -start=>1,
      -end=>$gbseq->length,
      -tag=>{
        organism=>join(" ",$species_obj->binomial,$species_obj->sub_species),
        mol_type=>"genomic DNA",
        project=>join(" ",$species_obj->sub_species),
      },
    );
    $gbseq->add_SeqFeature($sourceFeature);

    my @preds_for_seq;
    foreach my $strand (keys %{$$predictions{$seqname}}) {
      push(@preds_for_seq, values(%{$$predictions{$seqname}->{$strand}}));
    }

    foreach my $pred (sort {$$a{stop} <=> $$b{stop}} @preds_for_seq) {
      my $nt_seq = substr($$seqs{$seqname}, min($$pred{start}, $$pred{stop})-1, abs($$pred{start} - $$pred{stop})+1);
      if ($$pred{strand} eq '-') {
        $nt_seq = reverse($nt_seq); $nt_seq =~ tr/ATGC/TACG/;
      }

      my $pred_gene_feature = new Bio::SeqFeature::Generic(-primary_tag => 'gene',
        -start => $$pred{lo},
        -end => $$pred{hi},
        -strand => ($$pred{strand} eq '+' ? 1 : -1),
      );
      my $pred_feature = new Bio::SeqFeature::Generic(-primary_tag => $$pred{type},
        -start => $$pred{lo},
        -end => $$pred{hi},
        -strand => ($$pred{strand} eq '+' ? 1 : -1),
      );

      if ($$pred{type} eq 'CDS') {
        my $locus_tag = $cds_tag_factory->nextTag();
        $pred_gene_feature->add_tag_value('locus_tag', $locus_tag);
        $pred_feature->add_tag_value('locus_tag', $locus_tag);
        my $aa_seq = AKUtils::dna2aa($nt_seq);
        # Note: transl_table was making results unreadable in Apollo
        #$pred_feature->add_tag_value('transl_table', $$settings{prediction_transl_table});
        $pred_feature->add_tag_value('translation', substr($aa_seq, 0, length($aa_seq)-1));
        $pred_feature->add_tag_value('evidence', 'predicted');
        $pred_feature->add_tag_value('note', 'Predictors: '.join(', ', @{$$pred{predictor}}));
      } elsif ($$pred{type} eq 'tRNA') {
        my $locus_tag = $trna_tag_factory->nextTag();
        $pred_gene_feature->add_tag_value('locus_tag', $locus_tag);
        $pred_feature->add_tag_value('locus_tag', $locus_tag);
        $pred_feature->add_tag_value('evidence', 'predicted');
        $pred_feature->add_tag_value('note', 'Predictors: '.join(', ', @{$$pred{predictor}}));
        $pred_feature->add_tag_value('product', 'tRNA-'.$$pred{trna_type});
        $pred_feature->add_tag_value('note', 'codon recognized: '.$$pred{trna_codon_recognized});
      } elsif ($$pred{type} eq 'rRNA') {
        my $locus_tag = $rrna_tag_factory->nextTag();
        $pred_gene_feature->add_tag_value('locus_tag', $locus_tag);
        $pred_feature->add_tag_value('locus_tag', $locus_tag);
        $pred_feature->add_tag_value('evidence', 'predicted');
        $pred_feature->add_tag_value('note', 'Predictors: '.join(', ', @{$$pred{predictor}}));
        $pred_feature->add_tag_value('product', $$pred{rrna_type});
        # TODO: Finish me
      } elsif ($$pred{type} eq 'repeat_region') { # CRISPRs
        my $locus_tag = $crispr_tag_factory->nextTag();
        $pred_gene_feature->add_tag_value('locus_tag', $locus_tag);
        $pred_feature->add_tag_value('locus_tag', $locus_tag);
        $pred_feature->add_tag_value('evidence', 'predicted');
        $pred_feature->add_tag_value('note', 'Predictors: '.join(', ', @{$$pred{predictor}}));
        # CRISPRs are direct repeats
        $pred_feature->add_tag_value('rpt_type','direct');
      }else { die "Internal error: cannot understand feature type $$pred{type}" }

      $gbseq->add_SeqFeature($pred_gene_feature);
      $gbseq->add_SeqFeature($pred_feature);
    }

    # remove linkers and reset gene coordinates
    my $numLinkers=removeLinkers($gbseq,$settings);

    # write the final sequence with gene predictions to the file
    $gb_out_h->write_seq($gbseq);
  }
  
  return $$settings{outfile};
}

sub usage{
  "Reconciles gene predictions
  Usage: $0 gene.predictions -o outfile.gff -m 2
  Where gene.predictions can be the following output files:
    glimmer3.predict, itr_3.lst, prodigal.gff, other.gff
  -t tempdir/
  -m minimum predictors to call an orf (Default: 1)
  "
}
