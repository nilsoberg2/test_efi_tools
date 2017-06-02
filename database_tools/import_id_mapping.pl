#!/usr/bin/perl -w
use strict;
use FindBin;
use lib "$FindBin::Bin/../lib/";
use Biocluster::IdMapping::Builder;
use Biocluster::Database;
use Getopt::Long;

my ($cfgFile, $buildDir, $idMappingFile, $outputFile, $loadDb);
GetOptions(
    "config=s"      => \$cfgFile,
    "build=s"       => \$buildDir,
    "idmapping=s"   => \$idMappingFile,
    "output=s"      => \$outputFile,
    "load-db"       => \$loadDb,
);


if (not defined $cfgFile or not -f $cfgFile) {
    if (exists $ENV{EFICONFIG}) {
        $cfgFile = $ENV{EFICONFIG};
    } else {
        die "--config file parameter is not specified.  module load efiest_v2 should take care of this.";
    }
}

die "--idmapping=id_mapping.dat input file must be provided" unless (defined $idMappingFile and -f $idMappingFile);
die "--output=output_tab_file must be provided" unless defined $outputFile;

$buildDir = "" if not defined $buildDir;
my $mapBuilder = new Biocluster::IdMapping::Builder(config_file_path => $cfgFile, build_dir => $buildDir);


my $resCode = $mapBuilder->parse($outputFile, undef, $idMappingFile, 1);

if (defined $loadDb) {
    my $db = new Biocluster::Database(config_file_path => $cfgFile);
    my $mapTable = $db->{id_mapping}->{table};
    $db->dropTable($mapTable) if ($db->tableExists($mapTable));
    $db->createTable($mapBuilder->getTableSchema());
    $db->tableExists($mapTable);
    $db->loadTabular($mapTable, $outputFile);
}

