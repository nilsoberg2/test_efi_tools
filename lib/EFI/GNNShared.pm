
package EFI::GNNShared;

use List::MoreUtils qw{apply uniq any};
use List::Util qw(sum);
use Array::Utils qw(:all);

use Exporter 'import';
@EXPORT = qw(median writeGnnField writeGnnListField);


sub new {
    my ($class, %args) = @_;

    my $self = {};
    bless($self, $class);

    $self->{dbh} = $args{dbh};
    $self->{incfrac} = $args{incfrac};
    $self->{colors} = $self->getColors();
    $self->{id_dir} = ($args{id_dir} and -d $args{id_dir}) ? $args{id_dir} : "";
    $self->{cluster_fh} = {};
    $self->{color_only} = exists $args{color_only} ? $args{color_only} : 0;

    return $self;
}


sub getNodesAndEdges{
    my $self = shift @_;
    my $reader=shift @_;

    my @nodes=();
    my @edges=();
    $parser = XML::LibXML->new();
    $reader->read();
    if($reader->nodeType==8){ #node type 8 is a comment
        print "XGMML made with ".$reader->value."\n";
        $reader->read; #we do not want to start reading a comment
    }
    my $graphname=$reader->getAttribute('label');
    my $firstnode=$reader->nextElement();
    my $tmpstring=$reader->readOuterXml;
    my $tmpnode=$parser->parse_string($tmpstring);
    my $node=$tmpnode->firstChild;
    push @nodes, $node;
    while($reader->nextSiblingElement()){
        $tmpstring=$reader->readOuterXml;
        $tmpnode=$parser->parse_string($tmpstring);
        $node=$tmpnode->firstChild;
        if($reader->name() eq "node"){
            push @nodes, $node;
        }elsif($reader->name() eq "edge"){
            push @edges, $node;
        }else{
            warn "not a node or an edge\n $tmpstring\n";
        }
    }
    return ($graphname, \@nodes, \@edges);
}

sub getNodes{
    my $self = shift @_;
    my $nodes = shift @_;

    my %nodehash;
    my %nodenames;
    my %nodeMap;

    print "parse nodes for accessions\n";
    foreach $node (@{$nodes}){
        $nodehead=$node->getAttribute('label');
        #cytoscape exports replace the id with an integer instead of the accessions
        #%nodenames correlates this integer back to an accession
        #for efiest generated networks the key is the accession and it equals an accession, no harm, no foul
        $nodenames{$node->getAttribute('id')}=$nodehead;
        my @annotations=$node->findnodes('./*');
        push @{$nodehash{$nodehead}}, $nodehead;
        $nodeMap{$nodehead} = $node;
        foreach $annotation (@annotations){
            if($annotation->getAttribute('name') eq "ACC"){
                my @accessionlists=$annotation->findnodes('./*');
                foreach $accessionlist (@accessionlists){
                    #make sure all accessions within the node are included in the gnn network
                    my $attrAcc = $accessionlist->getAttribute('value');
                    push @{$nodehash{$nodehead}}, $attrAcc if $nodehead ne $attrAcc;
                    $nodeMap{$nodehead} = $node;
                }
            }
        }
    }

    return \%nodehash, \%nodenames, \%nodeMap;
}

sub getClusters{
    my $self = shift @_;
    my $nodehash = shift @_;
    my $nodenames = shift @_;
    my $edges = shift @_;
    my $nodeMap = shift @_;
    my $includeSingletons = shift @_;

    my %constellations=();
    my %supernodes=();
    my %singletons;
    my $newnode=1;

    foreach $edge (@{$edges}){
        my $edgeSource = $edge->getAttribute('source');
        my $edgeTarget = $edge->getAttribute('target');
        my $nodeSource = $nodenames->{$edgeSource};
        my $nodeTarget = $nodenames->{$edgeTarget};

        if (exists $nodeMap->{$nodeSource}) {

        }

        #if source exists, add target to source sc
        if(exists $constellations{$nodeSource}){
            #if target also already existed, add target data to source 
            if(exists $constellations{$nodeTarget}){
                #check if source and target are in the same constellation, if they are, do nothing, if not,
                # add change target sc to source and add target accessions to source accessions.
                # this is to handle the case that we've built two sub-constellations that are actually part
                # of a bigger constellation.
                unless($constellations{$nodeTarget} eq $constellations{$nodeSource}){
                    #add accessions from target supernode to source supernode
                    push @{$supernodes{$constellations{$nodeSource}}}, @{$supernodes{$constellations{$nodeTarget}}};
                    #delete target supernode
                    delete $supernodes{$constellations{$nodeTarget}};
                    #change the constellation number for all 
                    $oldtarget=$constellations{$nodeTarget};
                    foreach my $tmpkey (keys %constellations){
                        if($oldtarget==$constellations{$tmpkey}){
                            $constellations{$tmpkey}=$constellations{$nodeSource};
                        }
                    }
                }
            }else{
                #target does not exist, add it to source
                #change cluster number
                $constellations{$nodeTarget}=$constellations{$nodeSource};
                #add accessions
                push @{$supernodes{$constellations{$nodeSource}}}, @{$nodehash->{$nodeTarget}};
            }
        }elsif(exists $constellations{$nodeTarget}){
            #target exists, add source to target sc
            #change cluster number
            $constellations{$nodeSource}=$constellations{$nodeTarget};
            #add accessions
            push @{$supernodes{$constellations{$nodeTarget}}}, @{$nodehash->{$nodeSource}};
        }else{
            #neither exists, add both to same sc, and add accessions to supernode
            $constellations{$nodeSource}=$newnode;
            $constellations{$nodeTarget}=$newnode;
            push @{$supernodes{$newnode}}, @{$nodehash->{$nodeSource}};
            push @{$supernodes{$newnode}}, @{$nodehash->{$nodeTarget}};
            #increment for next sc node
            $newnode++;
        }
    }

    if ($includeSingletons) {
        # Look at each node in the network.  If we haven't processed it above (i.e. it doesn't have any edges attached)
        # then we add a new supernode and add any represented nodes (if it is a repnode).
        foreach my $nodeName (keys %$nodenames) {
            if (not exists $constellations{$nodeName}) {
                $supernodes{$newnode} = $nodehash->{$nodeName}; # nodehash contains an array of nodes, since it may be a repnode
                $singletons{$nodeName} = $newnode;
                $constellations{$nodeName} = $newnode;
                $newnode++;
            }
        }
    }

    return \%supernodes, \%constellations, \%singletons;
}

sub numberClusters {
    my $self = shift @_;
    my $supernodes = shift @_;
    my $useExistingNumber = shift @_;

    my %numbermatch=();
    my $simplenumber=1;
    my @numberOrder;

    foreach my $clusterNode (sort { my $c = $#{$supernodes->{$b}} <=> $#{$supernodes->{$a}};
                                    $c = $a <=> $b if not $c; # handle equals case
                                    $c } keys %$supernodes){
        $simplenumber = $clusterNode if $useExistingNumber;
        print "Supernode $clusterNode, ".scalar @{$supernodes->{$clusterNode}}." original accessions, simplenumber $simplenumber\n";
        $numbermatch{$clusterNode}=$simplenumber;
        push @numberOrder, $clusterNode;
        $simplenumber++;
    }

    return \%numbermatch, \@numberOrder;
}

sub hasExistingNumber {
    my $self = shift @_;
    my $nodes = shift @_;

    my $node = $nodes->[0];

    return 0;
}

sub writeColorSsn {
    my $self = shift @_;
    my $nodes = shift @_;
    my $edges = shift @_;
    my $title = shift @_;
    my $writer = shift @_;
    my $numbermatch = shift @_;
    my $constellations = shift @_;
    my $nodenames = shift @_;
    my $supernodes = shift @_;
    my $gnnData = shift @_;

    $writer->startTag('graph', 'label' => "$title colorized", 'xmlns' => 'http://www.cs.rpi.edu/XGMML');
    $self->writeColorSsnNodes($nodes, $writer, $numbermatch, $constellations, $supernodes, $gnnData);
    $self->writeColorSsnEdges($edges, $writer, $nodenames);
    $writer->endTag(); 
}

sub saveGnnAttributes {
    my $self = shift;
    my $writer = shift;
    my $gnnData = shift;
    my $node = shift;
}

sub writeColorSsnNodes {
    my $self = shift @_;
    my $nodes=shift @_;
    my $writer=shift @_;
    my $numbermatch=shift @_;
    my $constellations=shift @_;
    my $supernodes = shift @_;
    my $gnnData = shift @_;

    my %nodeCount;

    foreach my $node (@{$nodes}){
        my $nodeId = $node->getAttribute('label');
        my $clusterId = $constellations->{$nodeId};
        my $clusterNum = $numbermatch->{$clusterId};

        # In a previous step, we included singletons (historically they were excluded).
        unless($clusterNum eq ""){
            $nodeCount{$clusterNum} = scalar @{ $supernodes->{$clusterId} } if not exists $nodeCount{$clusterNum};
            $self->saveNodeToClusterMap($clusterId, $numbermatch, $supernodes, $gnnData);
            $writer->startTag('node', 'id' => $nodeId, 'label' => $nodeId);

            # find color and add attribute
            my $color = "";
            $color = $self->{colors}->{$clusterNum} if $nodeCount{$clusterNum} > 1;

            writeGnnField($writer, 'node.fillColor', 'string', $color);
            writeGnnField($writer, 'Cluster Number', 'integer', $clusterNum);
            writeGnnField($writer, 'Cluster Sequence Count', 'integer', $nodeCount{$clusterNum});

            if (not $self->{color_only}) {
                $self->saveGnnAttributes($writer, $gnnData, $node);
            }

            foreach $attribute ($node->getChildnodes){
                if($attribute=~/^\s+$/){
                    #print "\t badattribute: $attribute:\n";
                    #the parser is returning newline xml fields, this removes it
                    #code will break if we do not remove it.
                }else{
                    my $attrType = $attribute->getAttribute('type');
                    my $attrName = $attribute->getAttribute('name');
                    if($attrType eq 'list'){
                        $writer->startTag('att', 'type' => $attrType, 'name' => $attrName);
                        foreach $listelement ($attribute->getElementsByTagName('att')){
                            $writer->emptyTag('att', 'type' => $listelement->getAttribute('type'),
                                              'name' => $listelement->getAttribute('name'),
                                              'value' => $listelement->getAttribute('value'));
                        }
                        $writer->endTag;
                    }elsif($attrName eq 'interaction'){
                        #do nothing
                        #this tag causes problems and it is not needed, so we do not include it
                    }else{
                        if(defined $attribute->getAttribute('value')){
                            $writer->emptyTag('att', 'type' => $attrType, 'name' => $attrName,
                                              'value' => $attribute->getAttribute('value'));
                        }else{
                            $writer->emptyTag('att', 'type' => $attrType, 'name' => $attrName);
                        }
                    }
                }
            }
            $writer->endTag(  );
        } else {
            print "Node $nodeId was found in any of the clusters we built today\n";
        }
    }
}

sub writeColorSsnEdges {
    my $self = shift @_;
    my $edges=shift @_;
    my $writer=shift @_;
    my $nodenames=shift @_;

    foreach $edge (@{$edges}){
        $writer->startTag('edge', 'id' => $edge->getAttribute('id'), 'label' => $edge->getAttribute('label'), 'source' => $nodenames->{$edge->getAttribute('source')}, 'target' => $nodenames->{$edge->getAttribute('target')});
        foreach $attribute ($edge->getElementsByTagName('att')){
            if($attribute->getAttribute('name') eq 'interaction' or $attribute->getAttribute('name')=~/rep-net/){
                #print "do nothing\n";
                #this tag causes problems and it is not needed, so we do not include it
            }else{
                $writer->emptyTag('att', 'name' => $attribute->getAttribute('name'), 'type' => $attribute->getAttribute('type'), 'value' =>$attribute->getAttribute('value'));
            }
        }
        $writer->endTag;
    }
}


sub saveNodeToClusterMap {
    my $self = shift @_;
    my $clusterId = shift @_;
    my $numbermatch = shift @_;
    my $supernodes = shift @_;
    my $gnnData = shift @_;

    return if not $self->{id_dir} or not -d $self->{id_dir} or exists $self->{cluster_map_processed}->{$clusterId};

    $self->{cluster_map_processed}->{$clusterId} = 1;

    my $clusterNum = $numbermatch->{$clusterId};
    $clusterNum = "none" if not $clusterNum;

    if (not exists $self->{cluster_fh}->{$clusterNum}) {
        open($self->{cluster_fh}->{$clusterNum}, ">" . $self->{id_dir} . "/cluster_nodes_$clusterNum.txt");
    }

    my $printToPfam = not $self->{color_only} and not exists $self->{no_pfam_fh}->{$clusterNum};
    if ($printToPfam) {
        open($self->{no_pfam_fh}->{$clusterNum}, ">" . $self->{id_dir} . "/cluster_no_pfam_$clusterNum.txt");
    }

    foreach my $nodeId (@{ $supernodes->{$clusterId} }) {
        $self->{cluster_fh}->{$clusterNum}->print("$nodeId\n");
        $self->{no_pfam_fh}->{$clusterNum}->print("$nodeId\n") if $printToPfam and exists $gnnData->{noneFamily}->{$clusterNum}->{$nodeId};
    }
}


sub writeIdMapping {
    my $self = shift @_;
    my $idMapPath = shift @_;
    my $numbermatch = shift @_;
    my $constellations = shift @_;
    my $supernodes = shift @_;

    open IDMAP, ">$idMapPath";

    print IDMAP "UniProt_ID\tCluster_Num\tCluster_Color\n";
    my @data;
    foreach my $clusterId (sort keys %$supernodes) {
        my $clusterNum = $numbermatch->{$clusterId};
        foreach my $nodeId (@{ $supernodes->{$clusterId} }) {
            push @data, [$nodeId, $clusterNum, $self->{colors}->{$clusterNum}];
        }
    }

    foreach my $row (sort idmapsort @data) {
        print IDMAP join("\t", @$row), "\n";
    }

    close IDMAP;
}


sub idmapsort {
    my $comp = $a->[1] <=> $b->[1];
    if ($comp == 0) {
        return $a->[0] cmp $b->[0];
    } else {
        return $comp;
    }
}


sub closeClusterMapFiles {
    my $self = shift @_;

    return if not $self->{id_dir} or not -d $self->{id_dir};

    foreach my $key (keys %{ $self->{cluster_fh} }) {
        close($self->{cluster_fh}->{$key});
    }

    foreach my $key (keys %{ $self->{no_pfam_fh} }) {
        close($self->{no_pfam_fh}->{$key});
    }
}


sub getColors {
    my $self = shift @_;

    my %colors=();
    my $sth=$self->{dbh}->prepare("select * from colors;");
    $sth->execute;
    while(my $row=$sth->fetchrow_hashref){
        $colors{$row->{cluster}}=$row->{color};
    }
    return \%colors;
}

sub median{
    my @vals = sort {$a <=> $b} @_;
    my $len = @vals;
    if($len%2) #odd?
    {
        return $vals[int($len/2)];
    }
    else #even
    {
        return ($vals[int($len/2)-1] + $vals[int($len/2)])/2;
    }
}

sub writeGnnField {
    my $writer=shift @_;
    my $name=shift @_;
    my $type=shift @_;
    my $value=shift @_;

    unless($type eq 'string' or $type eq 'integer' or $type eq 'real'){
        die "Invalid GNN type $type\n";
    }

    $writer->emptyTag('att', 'name' => $name, 'type' => $type, 'value' => $value);
}

sub writeGnnListField {
    my $writer=shift @_;
    my $name=shift @_;
    my $type=shift @_;
    my $valuesIn=shift @_;
    my $toSortOrNot=shift @_;

    unless($type eq 'string' or $type eq 'integer' or $type eq 'real'){
        die "Invalid GNN type $type\n";
    }
    $writer->startTag('att', 'type' => 'list', 'name' => $name);
    
    my @values;
    if (defined $toSortOrNot and $toSortOrNot) {
        @values = sort @$valuesIn;
    } else {
        @values = @$valuesIn;
    }

    foreach my $element (@values){
        $writer->emptyTag('att', 'type' => $type, 'name' => $name, 'value' => $element);
    }
    $writer->endTag;
}

1;

