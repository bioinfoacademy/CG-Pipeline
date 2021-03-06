#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use Bio::Perl;
use Data::Dumper;
use File::Basename;
use LWP::Simple;
use FindBin;
use lib "$FindBin::RealBin/../lib";
$ENV{PATH} = "$FindBin::RealBin:".$ENV{PATH};
use AKUtils;
# TODO multithread SeqIO/in
# TODO buffer the output
# TODO download the correct genus files
sub logmsg{print STDERR "@_\n";}
exit main();
sub main{
  my $settings={
    cluster=>1,
  };
  GetOptions($settings,qw(help tempdir=s numcpus=i cluster! need-genes)) or die;
  die usage() if($$settings{help});
  die "ERROR: need fasta files\n".usage() if(!@ARGV);
  $$settings{tempdir}||=AKUtils::mktempdir(); mkdir($$settings{tempdir}) if(!-d $$settings{tempdir});
  $$settings{numcpus}||=1;
  $$settings{maxmem}||=int(AKUtils::getFreeMem() * 0.75+ 1); # 75% of free memory plus one byte to avoid zero
  $$settings{'need-genes'}||=0;
  my @fasta=@ARGV;
  for(@fasta){
    die "ERROR: I could not find fasta file $_" if(!-f $_);
  }

  my @genera=getGenera($settings);
  my $filtered=filterByGenusAndReformatDefline(\@fasta,\@genera,$settings);
  my $clustered=clusterSequences($filtered,$settings) if($$settings{cluster});
  system("cat '$clustered'"); die if $?;
  return 0;
}
sub getGenera{
  my($settings)=@_;
  # download the taxonomy html files
  my $html;
  for my $url(qw(http://www.bacterio.net/-ac.html http://www.bacterio.net/-dl.html http://www.bacterio.net/-mr.html http://www.bacterio.net/-sz.html)){
    logmsg "Downloading $url";
    $html.=get($url);
  }
  logmsg "Finding genus names";
  my @genus;
  for my $line(split(/\n/,$html)){
    while($line=~/'genusspecies'>(\w+)</gi){
      push(@genus,$1);
    }
  }
  return @genus;
}
sub filterByGenusAndReformatDefline{
  my($fastaArr,$genus,$settings)=@_;
  my $outfile="$$settings{tempdir}/filtered.renamed.fasta";
  my $tmpfile="$outfile.tmp";
  my $out=Bio::SeqIO->new(-format=>"fasta",-file=>">$tmpfile");
  my $genusRegex=join("|",@$genus);
  my @seqBuffer;
  for my $fastain(@$fastaArr){
    logmsg "Reading $fastain and writing to temporary file $tmpfile";
    
    # decide if this is a gunzipped file
    my $in;
    my($name,$path,$suffix)=fileparse($fastain,qw(.gz));
    if($suffix eq '.gz'){
      $in=Bio::SeqIO->new(-format=>"fasta",-file=>"gunzip -c '$fastain' | ");
    }else{
      $in=Bio::SeqIO->new(-file=>$fastain,-format=>"fasta");
    }
    my $i=0;
    my $writtenCounter=0;
    while(my $seq=$in->next_seq){
      if(++$i % 100000 == 0){
        $out->write_seq(@seqBuffer);
        $writtenCounter+=@seqBuffer;
        @seqBuffer=();

        my $percent=sprintf("%0.2f",$writtenCounter/$i*100);
        logmsg "$percent% written out of the current $i entries ($writtenCounter).";
      }
      my $id=$seq->id." ".$seq->desc;
      next if($id !~ /$genusRegex/);
      my($seqid,$product,$gene,$EC,$xref)=("","","","","");
      # Get the sequence identifier and the product
      if($id=~/^\s*(\S+)\s+(.*?)\s*\w+=/){ # regex: first nonwhitespace; next nonwhitespace until any key/value pair with an equals sign
        ($seqid,$product)=($1,$2);
      }
      # Get the gene name
      if($id =~ /GN=(\S+)/){
        $gene=$1;
      } else {
        # Ignore this gene entirely if there is no gene name and you want them
        next if($$settings{'need-genes'});
      }

      # get the xref if possible
      # e.g. sp|P0A5B8|14KD_MYCBO => 14KD_MYCBO
      if($id=~/(\w+)\|(\w+)(\|(\w+))?/){
        $xref=$4;
      }

      # (EC 3.4.19.1)
      # EC numbers can end with a dash to show that the catalytic activity of the protein is not known exactly.
      # EC numbers can end with an n and a number to show that it catalyzes a reaction that is known but not yet included in the IUBMB EC list.
      if($id=~/(\d+(\.\d+){3})/){
        $EC=$1;
      }
      $seq->id($seqid);
      $seq->desc(join("~~~",$xref,$EC,$gene,$product));
      push(@seqBuffer,$seq);
    }
    # finish writing the rest to file
    $out->write_seq(@seqBuffer);
    $writtenCounter+=@seqBuffer;
    @seqBuffer=();
  }
  system ("mv -v '$tmpfile' '$outfile' 1>&2"); die if $?;
  return $outfile;
}
sub clusterSequences{
  my($filtered,$settings)=@_;
  my $clusterfile="$$settings{tempdir}/clustered.fasta";
  my $freeMb=int($$settings{maxmem}/1024/1024) + 1; # add one to avoid zero
  my $command="cd-hit -i '$filtered' -o '$clusterfile' -T $$settings{numcpus} -M $freeMb -g 1 -s 0.8 -c 0.9";
  logmsg "Clustering using cd-hit, maximum memory: $freeMb MB. Temporary file: $clusterfile\n  $command";
  system("$command 1>&2");
  die if $?;
  return $clusterfile;
}

sub usage{
  local $0=fileparse $0;
  "Filters a uniprot-style fasta file with the genera in the bacterial kingdom. Entries with no gene name are also filtered out if --need-genes is specified. Then, filtered genes are clustered with cd-hit to reduce the size of the database.
  Deflines will be in the format of ~~~
  Usage: $0 uniprot.fasta[.gz] [uniprot2.fasta[.gz] ...] > filtered.fasta
  --numcpus 1   Number of cpus
  --need-genes  To skip any entries without a gene name
  --nocluster   Do not cluster sequences with cd-hit
  -t tempdir/
  "
}

