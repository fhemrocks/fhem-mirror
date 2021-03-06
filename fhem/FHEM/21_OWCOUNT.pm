########################################################################################
#
# OWCOUNT.pm 
#
# FHEM module to commmunicate with 1-Wire Counter/RAM DS2423
#
# Prof. Dr. Peter A. Henning
# Norbert Truchsess
#
# $Id$
#
########################################################################################
#
# define <name> OWCOUNT [<model>] <ROM_ID> [interval] or OWCOUNT <FAM_ID>.<ROM_ID> [interval]
#
# where <name> may be replaced by any name string 
#     
#       <model> is a 1-Wire device type DS2423 or DS2423emu. If omitted, we assume this to be an
#              DS2423 Counter/RAM  
#       <FAM_ID> is a 1-Wire family id, currently allowed value is 1D
#       <ROM_ID> is a 12 character (6 byte) 1-Wire ROM ID 
#                without Family ID, e.g. A2D90D000800 
#       [interval] is an optional query interval in seconds
#
# get <name> id                  => FAM_ID.ROM_ID.CRC 
# get <name> present             => 1 if device present, 0 if not
# get <name> interval            => query interval
# get <name> memory <page>       => 32 byte string from page 0..13
# get <name> midnight  <channel> => todays starting value (formatted) for counter
# get <name> month               => summary and average for month
# get <name> year                => summary and average for year
# get <name> raw <channel>       => raw value for counter
# get <name> counters            => formatted values for both counters
# get <name> version             => OWX version number
#
# set <name> interval            => set query interval for measurement
# set <name> memory <page>       => 32 byte string into page 0..13
# set <name> midnight  <channel> => todays starting value for counter
#
# Additional attributes are defined in fhem.cfg, in some cases per channel, where <channel>=A,B
#
# attr <name> LogM <string> = device name (not file name) of monthly log file
# attr <name> LogY <string> = device name (not file name) of yearly log file
# attr <name> nomemory      = 1|0 (when set to 1, disabels use of internal memory)
# attr <name> <channel>Name <string>|<string> = name for the channel | a type description for the measured value
# attr <name> <channel>Unit <string>|<string> = unit of measurement for this channel | its abbreviation 
# attr <name> <channel>Rate <string>|<string> = name for the channel ratw | a type description for the measured value
# attr <name> <channel>Offset <float>  = offset added to the reading in this channel 
# attr <name> <channel>Factor <float>  = factor multiplied to (reading+offset) in this channel 
# attr <name> <channel>Mode <string>   = counting mode = normal(default) or daily
# attr <name> <channel>Period <string> = period for rate calculation  = hour (default), minute or second
#
# In normal counting mode each returned counting value will be factor*(reading+offset)
# In daily  counting mode each returned counting value will be factor*(reading+offset)-midnight
#           where midnight is stored as string in the 32 byte memory associated with the counter
#
# Log Lines
#    after each interval <date> <name> <channel>: <value> <unit> <value> / <unit>/<period> <channel>: <value> <unit> / <value> <unit>/<period> 
#          example: 2012-07-30_00:07:55 OWX_C Taste:  17.03 p 28.1 p/h B:  7.0 cts 0.0 cts/min
#    after midnight <new date> <name> <old day> <old date> <channel>: <value> <unit> <channel>: <value> <unit>   
#          example: 2012-07-30_00:00:57 OWX_C D29: 2012-7-29_23:59:59 Taste: 110.0 p, B:   7.0 cts
########################################################################################
#
#  This programm is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
########################################################################################
package main;

use vars qw{%attr %defs %modules $readingFnAttributes $init_done};
use strict;
use warnings;
sub Log($$);

my $owx_version="5.04";
#-- fixed raw channel name, flexible channel name
my @owg_fixed   = ("A","B");
my @owg_channel = ("A","B");
my @owg_rate    = ("A_rate","B_rate");

my %gets = (
  "id"          => "",
  "present"     => "",
  "interval"    => "",
  "memory"      => "",
  "midnight"    => "",
  "raw"         => "",
  "counters"    => "",
  "month"       => "",
  "year"        => "",
  "version"     => ""
);

my %sets = (
  "interval"    => "",
  "memory"      => "",
  "midnight"    => ""
);

my %updates = (
  "present"     => "",
  "counter"     => ""
);

########################################################################################
#
# The following subroutines are independent of the bus interface
#
# Prefix = OWCOUNT
#
########################################################################################
#
# OWCOUNT_Initialize
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWCOUNT_Initialize ($) {
  my ($hash) = @_;

  $hash->{DefFn}   = "OWCOUNT_Define";
  $hash->{UndefFn} = "OWCOUNT_Undef";
  $hash->{GetFn}   = "OWCOUNT_Get";
  $hash->{SetFn}   = "OWCOUNT_Set";
  $hash->{AttrFn}  = "OWCOUNT_Attr";
  #-- see header for attributes
  my $attlist = "IODev do_not_notify:0,1 showtime:0,1 model:DS2423,DS2423emu loglevel:0,1,2,3,4,5 LogM LogY ".
                "nomemory:1,0 interval ".
                $readingFnAttributes;
  for( my $i=0;$i<int(@owg_fixed);$i++ ){
    $attlist .= " ".$owg_fixed[$i]."Name";
    $attlist .= " ".$owg_fixed[$i]."Rate";
    $attlist .= " ".$owg_fixed[$i]."Offset";
    $attlist .= " ".$owg_fixed[$i]."Factor";
    $attlist .= " ".$owg_fixed[$i]."Unit";
    $attlist .= " ".$owg_fixed[$i]."Mode:normal,daily";
    $attlist .= " ".$owg_fixed[$i]."Period:hour,minute,second";
  }
  $hash->{AttrList} = $attlist; 
  
  #-- ASYNC this function is needed for asynchronous execution of the device reads 
  $hash->{AfterExecuteFn} = "OWXCOUNT_BinValues";
  #-- make sure OWX is loaded so OWX_CRC is available if running with OWServer
  main::LoadModule("OWX");	
}

#########################################################################################
#
# OWCOUNT_Define - Implements DefFn function
# 
# Parameter hash = hash of device addressed, def = definition string
#
#########################################################################################

sub OWCOUNT_Define ($$) {
  my ($hash, $def) = @_;
  
  my @a = split("[ \t][ \t]*", $def);
  my ($name,$model,$fam,$id,$crc,$interval,$scale,$ret);
  
  #-- default
  $name          = $a[0];
  $interval      = 300;
  $scale         = "";
  $ret           = "";

  #-- check syntax
  return "OWCOUNT: Wrong syntax, must be define <name> OWCOUNT [<model>] <id> [interval] or OWCOUNT <fam>.<id> [interval]"
       if(int(@a) < 2 || int(@a) > 5);
       
  #-- different types of definition allowed
  my $a2 = $a[2];
  my $a3 = defined($a[3]) ? $a[3] : "";
  #-- The model may be DS2423 or DS2423emu. Some weird people are violating 1-Wire integrity by using the 
  #   the same family ID although the DS2423emu does not fully support the DS2423 commands.
  #   Model attribute will be modified later when memory is checked
  #-- no model, 12 characters
  if( $a2 =~ m/^[0-9|a-f|A-F]{12}$/ ) {
    $model         = "DS2423";
    CommandAttr (undef,"$name model DS2423"); 
    $fam           = "1D";
    $id            = $a[2];
    if(int(@a)>=4) { $interval = $a[3]; }
  #-- no model, 2+12 characters
   } elsif(  $a2 =~ m/^[0-9|a-f|A-F]{2}\.[0-9|a-f|A-F]{12}$/ ) {
    $fam           = substr($a[2],0,2);
    $id            = substr($a[2],3);
    if(int(@a)>=4) { $interval = $a[3]; }
    if( $fam eq "1D" ){
      $model = "DS2423";
      CommandAttr (undef,"$name model DS2423"); 
    }else{
      return "OWCOUNT: Wrong 1-Wire device family $fam";
    }
  #-- model, 12 characters
  } elsif(  $a3 =~ m/^[0-9|a-f|A-F]{12}$/ ) {
    $model         = $a[2];
    $id            = $a[3];
    if(int(@a)>=5) { $interval = $a[4]; }
    if( $model eq "DS2423" ){
      $fam = "1D";
      CommandAttr (undef,"$name model DS2423"); 
    }elsif( $model eq "DS2423emu" ){
      $fam = "1D";
      CommandAttr (undef,"$name model DS2423emu"); 
      CommandAttr (undef,"$name nomemory 1"); 
    }else{
      return "OWCOUNT: Wrong 1-Wire device model $model";
    }
  } else {    
    return "OWCOUNT: $a[0] ID $a[2] invalid, specify a 12 or 2.12 digit value";
  }
   
  #   determine CRC Code - only if this is a direct interface
  $crc = sprintf("%02x",OWX_CRC($fam.".".$id."00"));
  
  #-- Define device internals
  $hash->{ROM_ID}     = "$fam.$id.$crc";
  $hash->{OW_ID}      = $id;
  $hash->{OW_FAMILY}  = $fam;
  $hash->{PRESENT}    = 0;
  $hash->{INTERVAL}   = $interval;
  $hash->{ASYNC}      = 0; #-- false for now
  
  #-- Couple to I/O device
  $hash->{IODev}=$attr{$name}{"IODev"} 
    if( defined($attr{$name}{"IODev"}) );
  AssignIoPort($hash);
  if( (!defined($hash->{IODev}->{NAME})) || (!defined($hash->{IODev}))  ){
    return "OWSWITCH: Warning, no 1-Wire I/O device found for $name.";
  }

  $modules{OWCOUNT}{defptr}{$id} = $hash;
  #--
  readingsSingleUpdate($hash,"state","defined",1);
  Log 3, "OWCOUNT: Device $name defined."; 
  
  #-- Start timer for updates
  InternalTimer(time()+10, "OWCOUNT_GetValues", $hash, 0);

  return undef; 
}

#######################################################################################
#
# OWCOUNT_Attr - Set one attribute value for device
#
#  Parameter hash = hash of device addressed
#            a = argument array
#
########################################################################################

sub OWCOUNT_Attr(@) {
  my ($do,$name,$key,$value) = @_;
  
  my $hash = $defs{$name};
  my $ret;
  
  if ( $do eq "set") {
  	ARGUMENT_HANDLER: {
  	  #-- interval modified at runtime
  	  $key eq "interval" and do {
        #-- check value
        return "OWCOUNT: Set with short interval, must be > 1" if(int($value) < 1);
        #-- update timer
        $hash->{INTERVAL} = $value;
        if ($init_done) {
          RemoveInternalTimer($hash);
          InternalTimer(gettimeofday()+$hash->{INTERVAL}, "OWCOUNT_GetValues", $hash, 1);
        }
  	    last;
  	  };
    }
  }
  return $ret;
}

########################################################################################
#
# OWCOUNT_ChannelNames - find the real channel names  
#
#  Parameter hash = hash of device addressed
#
########################################################################################

sub OWCOUNT_ChannelNames($) { 
  my ($hash) = @_;
 
  my $name    = $hash->{NAME}; 
  my $state   = $hash->{READINGS}{"state"}{VAL};
 
  my ($cname,@cnama,$unit,@unarr,$runit,$period);

  for (my $i=0;$i<int(@owg_fixed);$i++){
    #-- name
    $cname = defined($attr{$name}{$owg_fixed[$i]."Name"})  ? $attr{$name}{$owg_fixed[$i]."Name"} : $owg_fixed[$i]."|event";
    @cnama = split(/\|/,$cname);
    if( int(@cnama)!=2){
      Log 1, "OWCOUNT: Incomplete channel name specification $cname. Better use $cname|<type of data>"
        if( $state eq "defined");
      push(@cnama,"unknown");
    }
     #-- unit
    $unit = defined($attr{$name}{$owg_fixed[$i]."Unit"})  ? $attr{$name}{$owg_fixed[$i]."Unit"} : "counts|cts";
    @unarr= split(/\|/,$unit);
    if( int(@unarr)!=2 ){
      Log 1, "OWCOUNT: Incomplete channel unit specification $unit. Better use $unit|<abbreviation>"
        if( $state eq "defined");
      push(@unarr,"");  
    }
    
    #-- put into readings
    $owg_channel[$i]=$cnama[0];
    $hash->{READINGS}{$owg_channel[$i]}{TYPE}     = $cnama[1];  
    $hash->{READINGS}{$owg_channel[$i]}{UNIT}     = $unarr[0];
    $hash->{READINGS}{$owg_channel[$i]}{UNITABBR} = $unarr[1];
    
    $period  = defined($attr{$name}{$owg_fixed[$i]."Period"}) ? $attr{$name}{$owg_fixed[$i]."Period"} : "hour";
    #-- put into readings
    $hash->{READINGS}{$owg_channel[$i]}{PERIOD}   = $period; 

    #-- rate
    $cname = defined($attr{$name}{$owg_fixed[$i]."Rate"})  ? $attr{$name}{$owg_fixed[$i]."Rate"} : $cnama[0]."_rate|".$cnama[1]."_rate";
    @cnama = split(/\|/,$cname);
    if( int(@cnama)!=2){
      Log 1, "OWCOUNT: Incomplete rate name specification $cname. Better use $cname|<type of data>"
        if( $state eq "defined");
      push(@cnama,"unknown");
    }
   
    #-- rate unit
    my $runit = "";
    if(  $period eq "hour" ){
      $runit = "/h";
    }elsif( $period eq "minute" ){
      $runit = "/min";
    } else {
      $runit = "/s";
    }       
    #-- put into readings    
    $owg_rate[$i]=$cnama[0];
    $hash->{READINGS}{$owg_rate[$i]}{TYPE}     = $cnama[1];  
    $hash->{READINGS}{$owg_rate[$i]}{UNIT}     = $unarr[0].$runit;
    $hash->{READINGS}{$owg_rate[$i]}{UNITABBR} = $unarr[1].$runit;
   
    #-- some special cases
    #   Energy/Power
    $hash->{READINGS}{$owg_rate[$i]}{UNIT} = "kW"
      if ($unarr[0].$runit eq "kWh/h" );
    $hash->{READINGS}{$owg_rate[$i]}{UNITABBR} = "kW"
      if ($unarr[1].$runit eq "kWh/h" );
  }
}  

########################################################################################
#
# OWCOUNT_FormatValues - put together various format strings and assemble STATE variable
#
#  Parameter hash = hash of device addressed
#
########################################################################################

sub OWCOUNT_FormatValues($) {
  my ($hash) = @_;
  
  my $name    = $hash->{NAME}; 
  my ($offset,$factor,$period,$unit,$runit,$vval,$vrate);
  my ($svalue,$dvalue,$mvalue) = ("","","");
  my $galarm = 0;
 
  my ($sec, $min, $hour, $day, $month, $year, $wday,$yday,$isdst) = localtime(time);
  my ($seco,$mino,$houro,$dayo,$montho,$yearo,$dayrest);
  my ($daily, $dt,$dval,$dval2,$deltim,$delt,$delf);
  my ($total,$total0,$total1,$total2,$total3,@monthv,@yearv);
  my $daybreak = 0;
  my $monthbreak = 0;
  
  my $present  = $hash->{PRESENT};
  
  #-- no change in any value if invalid reading
  for (my $i=0;$i<int(@owg_fixed);$i++){
    return if( $hash->{owg_val}->[$i] eq "");
  }
  
  #-- obtain channel names
  OWCOUNT_ChannelNames($hash);
    
  #-- Check, whether we have a new day at the next reading
  $deltim = $hour*60.0+$min+$sec/60.0 - (1440 - $hash->{INTERVAL}/60.0);
  #$deltim = $min+$sec/60.0 - 55;
  if( $deltim>=0 ){
    $daybreak = 1;
    $monthbreak = 0;
    #-- Timer data from tomorrow
    my ($secn,$minn,$hourn,$dayn,$monthn,$yearn,$wdayn,$ydayn,$isdstn) = localtime(time() + $hash->{INTERVAL} + 3600);   
    #-- Check, whether we have a new month
    if( $dayn == 1 ){
      $monthbreak = 1;
    }
  }
    
  #-- put into READINGS
  readingsBeginUpdate($hash);
  
  #-- formats for output
  for (my $i=0;$i<int(@owg_fixed);$i++){
  
    #-- mode normal or daily
    $daily = 0;
    if( defined($attr{$name}{$owg_fixed[$i]."Mode"} )){ 
        if( $attr{$name}{$owg_fixed[$i]."Mode"} eq "daily"){
          $daily = 1;
        }
    }

    #-- offset and scale factor
    $offset  = defined($attr{$name}{$owg_fixed[$i]."Offset"}) ? $attr{$name}{$owg_fixed[$i]."Offset"} : 0;
    $factor  = defined($attr{$name}{$owg_fixed[$i]."Factor"}) ? $attr{$name}{$owg_fixed[$i]."Factor"} : 1; 
 
    #-- put into READINGS
    $hash->{READINGS}{$owg_channel[$i]}{OFFSET}  = $offset;  
    $hash->{READINGS}{$owg_channel[$i]}{FACTOR}  = $factor;  
    
    $unit     = $hash->{READINGS}{$owg_channel[$i]}{UNITABBR};
    $period   = $hash->{READINGS}{$owg_channel[$i]}{PERIOD};
    $runit    = $hash->{READINGS}{$owg_rate[$i]}{UNITABBR};
    
    #-- skip some things if undefined
    if( $hash->{owg_val}->[$i] eq ""){
      $svalue .= $owg_channel[$i].": ???";
    }else{     
      #-- only if attribute value mode=daily, take the midnight value from memory
      if( $daily == 1){
        $vval = int( (($hash->{owg_val}->[$i] + $offset)*$factor - $hash->{owg_midnight}->[$i])*10000+0.5)/10000; 
      } else {
        $vval = int( ($hash->{owg_val}->[$i] + $offset)*$factor*10000+0.5)/10000;
      }
      
      #-- rate calculation: get the old values
      my $oldval = $hash->{READINGS}{$owg_channel[$i]}{VAL};
      my $oldtim = $hash->{READINGS}{$owg_channel[$i]}{TIME};
      $oldtim = "" if(!defined($oldtim));
    
      #-- safeguard against the case where no previous measurement
      if( length($oldtim) > 0 ){    
        #-- correct counter wraparound since last reading
        if( $vval < $oldval) {
           $oldval -= (65536*$factor);
        }

        #-- previous measurement time
        ($yearo,$montho,$dayrest) = split(/-/,$oldtim);
        $dayo = substr($dayrest,0,2);
        ($houro,$mino,$seco) = split(/:/,substr($dayrest,3));
        
        #-- time difference to previous measurement and to midnight
        $delt = ($hour-$houro)*3600 + ($min-$mino)*60 + ($sec-$seco);
        $delf =  $hour        *3600 +  $min       *60 +  $sec - 86400;
        
        #-- rate
        if( ($delt > 0.0) && $present ){
          $vrate  = ($vval-$oldval)/$delt;
        } else {
          $vrate = 0.0;
        }
        #-- correct rate for period setting
        if(  $period eq "hour" ){
          $vrate*=3600;
        }elsif( $period eq "minute" ){
          $vrate*=60;
        }     
        $vrate = int($vrate * 10000+0.5)/10000;       
      
        #--midnight extrapolation only possible if previous measurement
        if( $daybreak==1 ){
          #--  linear extrapolation 
          $dt   = -$delf/$delt;
          $dval = int(($vval+($vval-$oldval)*$dt)*10000+0.5)/10000;
  
          if( $daily == 1 ){
            $dval2 = $dval+$hash->{owg_midnight}->[$i]; 
          } else {
            $dval2 = $dval;
          }
           
          #-- in any mode store the interpolated value in the midnight store
          OWCOUNT_SetPage($hash,14+$i,sprintf("%f",$dval2));
          
          #-- string buildup for monthly and yearly logging
          $dvalue .= sprintf( " %s: %5.1f %s %sM: %%5.1f %s",  $owg_channel[$i],$dval,$unit,$owg_channel[$i],$unit); 
          $mvalue .= sprintf( " %s: %%5.1fM %s %sY: %%5.1f %s", $owg_channel[$i],$unit,$owg_channel[$i],$unit); 
        } #-- end daybreak
      
        #-- string buildup for return value and STATE
        #-- 1 decimal
        if( $factor == 1.0 ){
          $svalue .= sprintf( "%s: %5.1f %s %s: %5.2f %s", $owg_channel[$i], $vval,$unit,$owg_rate[$i],$vrate,$runit);
        #-- 3 decimals
        } else {
          $svalue .= sprintf( "%s: %5.3f %s %s: %5.2f %s", $owg_channel[$i], $vval,$unit,$owg_rate[$i],$vrate,$runit);
        }  
      }
      readingsBulkUpdate($hash,$owg_channel[$i],$vval);
      readingsBulkUpdate($hash,$owg_rate[$i],$vrate);
    }
    #-- insert space 
    if( $i<int(@owg_fixed)-1 ){
      $svalue .= " ";
      $dvalue .= " ";
    }
  }#-- end channel loop
  
  #-- daybreak postprocessing
  if( $daybreak == 1 ){
    #-- daily/monthly accumulated value
    @monthv = OWCOUNT_GetMonth($hash);
    @yearv  = OWCOUNT_GetYear($hash);
    #-- error check
    if( int(@monthv) == 2 ){
      $total0 = $monthv[0]->[1];
      $total1 = $monthv[1]->[1];
    }else{
      Log 3,"OWCOUNT: No monthly summary possible, ".$monthv[0];
      $total0 = "";
      $total1 = "";
    };
    if( int(@yearv) == 2 ){
      $total2 = $yearv[0]->[1];
      $total3 = $yearv[1]->[1];
    }else{
      Log 3,"OWCOUNT: No yearly summary possible, ".$yearv[0];
      $total2 = "";
      $total3 = "";
    };
    #-- put in monthly and yearly sums
    $dvalue    = sprintf("D%02d ",$day).$dvalue;
    $dvalue    = sprintf($dvalue,$total0,$total1);
    readingsBulkUpdate($hash,"day",$dvalue);
    if ( $monthbreak == 1){
      $mvalue  = sprintf("M%02d ",$month+1).$mvalue;
      $mvalue  = sprintf($mvalue,$total2,$total3); 
      readingsBulkUpdate($hash,"month",$mvalue);
    }  
  }
      
  #-- STATE
  readingsBulkUpdate($hash,"state",$svalue);
  readingsEndUpdate($hash,1); 
  
  return $svalue;
}

########################################################################################
#
# OWCOUNT_Get - Implements GetFn function 
#
#  Parameter hash = hash of device addressed, a = argument array
#
########################################################################################

sub OWCOUNT_Get($@) {
  my ($hash, @a) = @_;
  
  my $reading = $a[1];
  my $name    = $hash->{NAME};
  my $model   = $hash->{OW_MODEL};
  my $value   = undef;
  my $ret     = "";
  my $page;
  my ($unit,$daily);
  my ($ret1,$ret2);

  #-- check syntax
  return "OWCOUNT: Get argument is missing @a"
    if(int(@a) < 2);
    
  #-- check argument
  return "OWCOUNT: Get with unknown argument $a[1], choose one of ".join(" ", sort keys %gets)
    if(!defined($gets{$a[1]}));

  #-- get id
  if($a[1] eq "id") {
    $value = $hash->{ROM_ID};
     return "$name.id => $value";
  } 
  
  #-- get present
  if($a[1] eq "present") {
    #-- hash of the busmaster
    my $master       = $hash->{IODev};
    $value           = OWX_Verify($master,$hash->{ROM_ID});
    $hash->{PRESENT} = $value;
    return "$name.present => $value";
  } 

  #-- get interval
  if($a[1] eq "interval") {
    $value = $hash->{INTERVAL};
     return "$name.interval => $value";
  } 
  
  #-- get version
  if( $a[1] eq "version") {
    return "$name.version => $owx_version";
  }
  
  #-- reset presence
  $hash->{PRESENT}  = 0;
  
  #-- get channel names
  OWCOUNT_ChannelNames($hash);
  
   #-- get month
  if($a[1] eq "month") {
    $value="$name.month =>\n";
    my @month2 = OWCOUNT_GetMonth($hash);
    #-- error case
    if( int(@month2) != 2 ){
      return $value." no monthly summary possible, ".$month2[0];
    }
    #-- 3 entries for each day
    for(my $i=0;$i<int(@month2);$i++){
      $unit   = $hash->{READINGS}{$owg_channel[$i]}{UNITABBR};
      #-- mode = daily ?
      $daily = 0;
      if( defined($attr{$name}{$owg_fixed[$i]."Mode"} )){ 
        if( $attr{$name}{$owg_fixed[$i]."Mode"} eq "daily"){
          $daily = 1;
        }
      }
      if( $daily==1){
        $value .= $owg_channel[$i]."M: ".$month2[$i]->[1]." ".$unit.
        " (monthly sum until now, average ".$month2[$i]->[2]." ".$unit."/d)\n";
      }else{
        $value .= $owg_channel[$i]."M: ".$month2[$i]->[1]." ".$unit." (last midnight)\n";
      }
    }
    return $value;
  } 
  
  #-- get year
  if($a[1] eq "year") {
    $value="$name.year =>\n";
    my @year2 = OWCOUNT_GetYear($hash);
    #-- error case
    if( int(@year2) != 2 ){
      return $value." no yearly summary possible, ".$year2[0];
    }
    #-- 3 entries for each month
    for(my $i=0;$i<int(@year2);$i++){
      $unit   = $hash->{READINGS}{$owg_channel[$i]}{UNITABBR};
      #-- mode = daily ?
      $daily = 0;
      if( defined($attr{$name}{$owg_fixed[$i]."Mode"} )){ 
        if( $attr{$name}{$owg_fixed[$i]."Mode"} eq "daily"){
          $daily = 1;
        }
      }
      if( $daily==1){
        $value .= $owg_channel[$i]."Y: ".$year2[$i]->[1]." ".$unit.
        " (yearly sum until now, average ".$year2[$i]->[2]." ".$unit."/d)\n";
      }else{
        $value .= $owg_channel[$i]."Y: ".$year2[$i]->[1]." ".$unit." (last month)\n";
      }
    }
    return $value;
  } 
  
  #-- get memory page/counter according to interface type
  my $interface= $hash->{IODev}->{TYPE};
  
  #-- check syntax for getting memory page 0..13 or midnight A/B
  my $nomemory  = defined($attr{$name}{"nomemory"}) ? $attr{$name}{"nomemory"} : 0;
  if( ($reading eq "memory") || ($reading eq "midnight") ){
    if( $reading eq "memory" ){
      return "OWCOUNT: Memory usage disabled"
        if( $nomemory==1 );
      return "OWCOUNT: Get needs parameter when reading memory: <page>"
        if( int(@a)<2 );
      $page=int($a[2]);
      if( ($page<0) || ($page>13) ){
        return "OWXCOUNT: Wrong memory page requested";
      }
    }else{
      return "OWCOUNT: get needs parameter when reading midnight: <channel>"
        if( int(@a)<2 );
      #-- find out which channel we have
      if( ($a[2] eq $owg_channel[0]) || ($a[2] eq "A") ){
        $page=14;
      }elsif( ($a[2] eq $owg_channel[1]) || ($a[2] eq "B") ){    
        $page=15;
      } else {
        return "OWCOUNT: Invalid midnight counter address, must be A, B or defined channel name"
      }
    }
    $ret = OWCOUNT_GetPage($hash,$page);
    
    #-- when we have a return code, we have an error
    if( $ret ){
      return "OWCOUNT: Could not get values from device $name, reason: ".$ret;
    }else{
      return "OWCOUNT: $name.$reading [$page] =>".$hash->{owg_str}->[$page];
    }
  }
  
  #-- check syntax for getting counter
  if( $reading eq "raw" ){
    return "OWCOUNT: Get needs parameter when reading raw counter: <channel>"
      if( int(@a)<2 );
    #-- find out which channel we have
    if( ($a[2] eq $owg_channel[0]) || ($a[2] eq "A") ){
      $page=14;
    }elsif( ($a[2] eq $owg_channel[1]) || ($a[2] eq "B") ){    
      $page=15;
    } else {
      return "OWCOUNT: Invalid counter address, must be A, B or defined channel name"
    }

    $ret = OWCOUNT_GetPage($hash,$page);
    if( defined($ret)  ){
      return "OWCOUNT: Could not get values from device $name, reason: ".$ret;
    }
    $hash->{PRESENT} = 1; 
    #-- only one counter will be returned
    return "OWCOUNT: $name.raw $a[2] => ".$hash->{owg_val}->[$page-14];   
    
  #-- check syntax for getting counters
  }elsif( $reading eq "counters" ){
    return "OWCOUNT: Get needs no parameter when reading counters"
      if( int(@a)==1 );
    $ret1 = OWCOUNT_GetPage($hash,14);
    $ret2 = OWCOUNT_GetPage($hash,15);
  
    #-- process results
    $ret .= $ret1
      if( defined($ret1) );
    $ret .= $ret2
      if( defined($ret2) );
    if( defined($ret1) || defined($ret2) ){
      return "OWCOUNT: Could not get values from device $name, reason: ".$ret;
    }
    $hash->{PRESENT} = 1; 
    #-- both counters will be returned
    return "OWCOUNT: $name.counters => ".$hash->{READINGS}{"state"}{VAL}; 
  }
}

#######################################################################################
#
# OWCOUNT_GetPage - Get a memory page
#
#  Parameter hash = hash of device addressed
#            page = page addressed
#
########################################################################################

sub OWCOUNT_GetPage ($$) {
  my ($hash, $page) = @_;
  
  #-- get memory page/counter according to interface type
  my $interface= $hash->{IODev}->{TYPE};
  my $name    = $hash->{NAME};
  my $ret; 
  
  #-- check if memory usage has been disabled
  my $nomemory  = defined($attr{$name}{"nomemory"}) ? $attr{$name}{"nomemory"} : 0;
  
  #-- even if memory usage has been disabled, we need to read the page because it contains the counter values
  if( ($nomemory==0) || (($nomemory==1) && ( ($page==14)||($page==15) )) ){
    #-- OWX interface
    if( $interface eq "OWX" ){
      $ret = OWXCOUNT_GetPage($hash,$page);
    #-- OWFS interface
    }elsif( $interface eq "OWServer" ){
      $ret = OWFSCOUNT_GetPage($hash,$page);
    #-- Unknown interface
    }else{
      return "OWCOUNT: GetPage with wrong IODev type $interface";
    }
    
    #-- process results
    if( defined($ret)  ){
      return "OWCOUNT: Could not get values from device $name, reason: ".$ret;
    } else {
      return undef
        if( $nomemory==0 );
    }
    #-- when nomemory==1, we need to read the files
    if( $page==14 ){
      $hash->{owg_str}->[14] = OWCOUNT_recall($hash,"OWCOUNT_".$name."_14.dat");
      return undef;
    }elsif( $page==15 ){
      $hash->{owg_str}->[15] = OWCOUNT_recall($hash,"OWCOUNT_".$name."_15.dat");
      return undef;
    } else {
      return "OWCOUNT: file recall with wrong page number";
    }
    
  } 
}

########################################################################################
#
# OWCOUNT_GetMonth Read monthly data from a file
#
# Parameter hash
#
# Returns total value up to last day, including this day and average including this day
#
########################################################################################

sub OWCOUNT_GetMonth($) {

  my ($hash) = @_;
  my $name   = $hash->{NAME};
  my $regexp = ".*$name.*";
  my $val;
  my @month  = ();
  my @month2 = ();
  my @mchannel;
  my @linarr; 
  my $day;
  my $line;
  my ($total,$total2,$daily,$deltim,$av);

  #-- Check current logfile 
  my $ln = $attr{$name}{"LogM"};
  if( !(defined($ln))){
    return "attribute LogM is missing";
  }
  
  #-- get channel names 
  OWCOUNT_ChannelNames($hash);
  
  my $lf = $defs{$ln}{currentlogfile};
  if( !(defined($lf))){
    return "logfile of LogM is missing";
  }
  
  #-- current date
  my ($csec,$cmin,$chour,$cday,$cmonth,$cyear,$cwday,$cyday,$cisdst) = localtime(time);
  
  my $ret  = open(OWXFILE, "< $lf" );
  if( $ret) {
    while( <OWXFILE> ){
      #-- line looks as 
      #   2013-06-25_23:57:57 DG.CT1 day: D25  W:  42.2 kWh Wm:  84.4 kWh  B: 2287295.7 cts Bm: 2270341.0 cts
      $line = $_;
      chomp($line);
      if ( $line =~ m/$regexp/i){  
        @linarr = split(' ',$line);
        if( int(@linarr)==4+6*int(@owg_fixed) ){
          $day = $linarr[3];
          $day =~ s/D_0+//;
          @mchannel = ();
          for (my $i=0;$i<int(@owg_fixed);$i++){
            $val = $linarr[5+6*$i];
            push(@mchannel,$val);
          }
          push(@month,[@mchannel]);
        }
      }
    }
    if( int(@month)==0 ){
      return "invalid logfile format in LogM"
        if( $cday!=1 );
    }
  } else { 
    return "cannot open logfile of LogM";
  }
  
    
  #-- sum and average
  for (my $i=0;$i<int(@owg_fixed);$i++){
    $total = 0.0;
    #-- summing only if mode daily (means daily reset !)
    $daily = 0;
    if( defined($attr{$name}{$owg_fixed[$i]."Mode"} )){ 
        if( $attr{$name}{$owg_fixed[$i]."Mode"} eq "daily"){
          $daily = 1;
        }
    }
    if( $daily==1){
      for (my $j=0;$j<int(@month);$j++){
        $total += $month[$j][$i];
      }
    }
    #-- add data from current day also for non-summed mode
    $total = int($total*100)/100;
    $total2 = int(100*($total+$hash->{READINGS}{$owg_channel[$i]}{VAL}))/100;
    #-- number of days so far, including the present day
    my $deltim = int(@month)+($chour+$cmin/60.0 + $csec/3600.0)/24.0;
    my $av = $deltim>0 ? int(100*$total2/$deltim)/100 : -1;
    #-- output format
    push(@month2,[($total,$total2,$av)]);
  } 
  return @month2; 
}

########################################################################################
#
# OWCOUNT_GetYear Read yearly data from a file
#
# Parameter hash
#
# Returns total value up to last month including this month and average including this day
#
########################################################################################

sub OWCOUNT_GetYear($) {

  my ($hash) = @_;
  my $name   = $hash->{NAME};
  my $regexp = ".*$name.*";
  my $val;
  my @year  = ();
  my @year2 = ();
  my @mchannel;
  my @linarr;
  my $month;
  my $line;
  my ($total,$total2,$daily,$deltim,$av);

  #-- Check current logfile 
  my $ln = $attr{$name}{"LogY"};
  if( !(defined($ln))){
    return "attribute LogY is missing";
  }
  
  #-- get channel names 
  OWCOUNT_ChannelNames($hash);
  
  #-- current date
  my ($csec,$cmin,$chour,$cday,$cmonth,$cyear,$cwday,$cyday,$cisdst) = localtime(time);
  
  my $lf = $defs{$ln}{currentlogfile};
  if( !(defined($lf))){
    return "logfile of LogY is missing";
  }
  
  my $ret  = open(OWXFILE, "< $lf" );
  if( $ret) {
    while( <OWXFILE> ){
      #-- line looks as 
      #   2013-05-31_23:57:57 DG.CT1 month: M05  W:  42.2 kWh Wy:  84.4 kWh  B: 2287295.7 cts By: 2270341.0 cts
      $line = $_;
      chomp($line);
      if ( $line =~ m/$regexp/i){  
        @linarr = split(' ',$line);
        if( int(@linarr)==4+6*int(@owg_fixed) ){
          $month = $linarr[3];
          $month =~ s/M_0+//;
          @mchannel = ();
          for (my $i=0;$i<int(@owg_fixed);$i++){
            $val = $linarr[5+6*$i];
            push(@mchannel,$val);
          }
          push(@year,[@mchannel]);
        }
      }
    }
    if( int(@year)==0 ){
      return "invalid logfile format in LogY"
         if($cmonth != 1);
    }
  } else { 
    return "cannot open logfile of LogY";
  }
  
    
  #-- sum and average
  my @month2 = OWCOUNT_GetMonth($hash);
  for (my $i=0;$i<int(@owg_fixed);$i++){
    $total = 0.0;
    #-- summing only if mode daily (means daily reset !)
    $daily = 0;
    if( defined($attr{$name}{$owg_fixed[$i]."Mode"} )){ 
        if( $attr{$name}{$owg_fixed[$i]."Mode"} eq "daily"){
          $daily = 1;
        }
    }
    if( $daily==1){
      for (my $j=0;$j<int(@year);$j++){
        $total += $year[$j][$i];
      }
    }else{
      $total = $year[int(@year)-1][$i]
        if (int(@year)>0);
    };
    
    #-- add data from current day also for non-summed mode
    $total = int($total*100)/100;
    $total2 = int(100*($total+$month2[$i]->[1]))/100;
    #-- number of days so far, including the present day
    my $deltim = $cyday+($chour+$cmin/60.0 + $csec/3600.0)/24.0;
    my $av = $deltim>0 ? int(100*$total2/$deltim)/100 : -1;
    #-- output format
    push(@year2,[($total,$total2,$av)]);
  } 
  return @year2; 
}

#######################################################################################
#
# OWCOUNT_GetValues - Updates the reading from one device
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWCOUNT_GetValues($) {
  my $hash    = shift;
  
  my $name    = $hash->{NAME};
  my $model   = $hash->{OW_MODEL};
  my $value   = "";
  my $ret     = "";
  my ($ret1,$ret2);
  
  #-- check if device needs to be initialized
  OWCOUNT_InitializeDevice($hash)
    if( $hash->{READINGS}{"state"}{VAL} eq "defined");

  #-- restart timer for updates
  RemoveInternalTimer($hash);
  InternalTimer(time()+$hash->{INTERVAL}, "OWCOUNT_GetValues", $hash, 1);
  
  #-- reset presence - 
  $hash->{PRESENT}  = 0;
  
  #-- Get readings according to interface type
  my $interface= $hash->{IODev}->{TYPE};
  if( $interface eq "OWX" ){
    $ret1 = OWXCOUNT_GetPage($hash,14);
    $ret2 = OWXCOUNT_GetPage($hash,15);
  }elsif( $interface eq "OWServer" ){
    $ret1 = OWFSCOUNT_GetPage($hash,14);
    $ret2 = OWFSCOUNT_GetPage($hash,15);
  }else{
    return "OWCOUNT: GetValues with wrong IODev type $interface";
  }
  
  #-- process results
  $ret .= $ret1
    if( defined($ret1) );
  $ret .= $ret2
    if( defined($ret2) );
  if( $ret ne ""  ){
    return "OWCOUNT: Could not get values from device $name, reason: ".$ret;
  }
  $hash->{PRESENT} = 1; 
 
  return undef;
}

########################################################################################
#
# OWCOUNT_InitializeDevice - delayed setting of initial readings and channel names  
#
#  Parameter hash = hash of device addressed
#
########################################################################################

sub OWCOUNT_InitializeDevice($) {
  my ($hash) = @_;
  
  my $name     = $hash->{NAME};
  #-- get memory page/counter according to interface type
  my $interface= $hash->{IODev}->{TYPE};
  
  my $olddata  = "";
  my $newdata  = "OWCOUNT ".$owx_version;
  my $ret      = "";
  $hash->{PRESENT}    = 0;
   
  #-- initial values
  for( my $i=0;$i<int(@owg_fixed);$i++) { 
    #-- initial readings 
    $hash->{owg_val}->[$i]      = "";
    $hash->{owg_midnight}->[$i] = "";
    $hash->{owg_str}->[$i]      = "";
  }

  
  #-- testing if it is the emulator
  #-- The model may be DS2423 or DS2423emu. Some weird people are violating 1-Wire integrity by using the 
  #   the same family ID although the DS2423emu does not fully support the DS2423 commands.
  #   Model attribute will be modified now after checking for memory
  #-- OWX interface
  if( $interface eq "OWX" ){
    $ret .= OWXCOUNT_GetPage($hash,0);
    $olddata = $hash->{owg_str}->[0];
    $ret  = OWXCOUNT_SetPage($hash,0,$newdata);
    $ret .= OWXCOUNT_GetPage($hash,0);
    $ret .= OWXCOUNT_SetPage($hash,0,$olddata); 
##Use of uninitialized value in concatenation (.) or string at 
##ERRORR /usr/share/fhem/FHEM/21_OWCOUNT.pm line 1100.
##Use of uninitialized value in concatenation (.) or string at 
##/usr/share/fhem/FHEM/21_OWCOUNT.pm line 1103.
##Use of uninitialized value in concatenation (.) or string at 
##/usr/share/fhem/FHEM/21_OWCOUNT.pm line 1104. 
  #-- OWFS interface
  }elsif( $interface eq "OWServer" ){
    $ret .= OWXCOUNT_GetPage($hash,0);
    $olddata = $hash->{owg_str}->[0];
    $ret  = OWFSCOUNT_SetPage($hash,0,$newdata);
    $ret .= OWFSCOUNT_GetPage($hash,0);
    $ret .= OWFSCOUNT_SetPage($hash,0,$olddata);  
  #-- Unknown interface
  }else{
    return "OWCOUNT: InitializeDevice with wrong IODev type $interface";
  }
  #-- Here we test if writing the memory is ok.
  if( substr($hash->{owg_str}->[0],0,length($newdata)) ne $newdata ){
     Log 1,"OWCOUNT: model attribute of $name set to DS2423emu because no memory found";
     CommandAttr (undef,"$name model DS2423emu"); 
     CommandAttr (undef,"$name nomemory 1"); 
  }
  
  #-- Set state to initialized
  readingsSingleUpdate($hash,"state","initialized",1);
  
  return undef;
}

#######################################################################################
#
# OWCOUNT_Set - Set one value for device
#
#  Parameter hash = hash of device addressed
#            a = argument array
#
########################################################################################

sub OWCOUNT_Set($@) {
  my ($hash, @a) = @_;
  
  my $key     = $a[1];
  my $value   = $a[2];
  
  #-- for the selector: which values are possible
  if (@a == 2){
    my $newkeys = join(" ", keys %sets);
    return $newkeys ;    
  }
  
  #-- check syntax
  return "OWCOUNT: Set needs at least one parameter"
    if( int(@a)<3 );
  #-- check argument
  if( !defined($sets{$a[1]}) ){
        return "OWCOUNT: Set with unknown argument $a[1]";
  }
  
  #-- define vars
  my $ret     = undef;
  my $page;
  my $data;
  my $name    = $hash->{NAME};
  my $model   = $hash->{OW_MODEL};
  my ($cname,@cnama,@channel);
    
  #-- set new timer interval
  if($key eq "interval") {
    # check value
    return "OWCOUNT: Set with short interval, must be > 1"
      if(int($value) < 1);
    # update timer
    $hash->{INTERVAL} = $value;
    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday()+$hash->{INTERVAL}, "OWCOUNT_GetValues", $hash, 1);
    return undef;
  }
  
  #-- get channel names
  OWCOUNT_ChannelNames($hash);
  
  #-- set memory page/counter according to interface type
  my $interface= $hash->{IODev}->{TYPE};
  
  #-- check syntax for setting memory page 0..13 or midnight A/B
  my $nomemory  = defined($attr{$name}{"nomemory"}) ? $attr{$name}{"nomemory"} : 0;
  if( ($key eq "memory") || ($key eq "midnight") ){
    if( $key eq "memory" ){
      return "OWCOUNT: Memory usage disabled"
        if( $nomemory==1 );
      return "OWCOUNT: Set needs parameter when writing memory: <page>"
        if( int(@a)<2 );
      $page=int($a[2]);
      if( ($page<0) || ($page>13) ){
        return "OWXCOUNT: Wrong memory page write attempted";
      }
    }else{
      return "OWCOUNT: Set needs parameter when writing midnight: <channel>"
        if( int(@a)<2 );
      #-- find out which channel we have
      if( ($a[2] eq $owg_channel[0]) || ($a[2] eq "A") ){
        $page=14;
      }elsif( ($a[2] eq $owg_channel[1]) || ($a[2] eq "B") ){    
        $page=15;
      } else {
        return "OWCOUNT: Invalid midnight counter address, must be A, B or defined channel name"
      }
    }
   
    $data=$a[3];
    for( my $i=4;$i<int(@a);$i++){
      $data.=" ".$a[$i];
    }
    if( length($data) > 32 ){
      Log 1,"OWXCOUNT: Memory data truncated to 32 characters";
      $data=substr($data,0,32);
    }elsif( length($data) < 32 ){
      for(my $i=length($data)-1;$i<32;$i++){
        $data.=" ";
      }
    }
    $ret = OWCOUNT_SetPage($hash,$page,$data);
 
    #-- process results
    if( defined($ret)  ){
      return "OWCOUNT: Could not set device $name, reason: ".$ret;
    }
  }
    
  #-- process results - we have to reread the device
  $hash->{PRESENT} = 1; 
  OWCOUNT_GetValues($hash);  
  Log 4, "OWCOUNT: Set $hash->{NAME} $key $value";
}

#######################################################################################
#
# OWCOUNT_SetPage - Set one value for device
#
#  Parameter hash = hash of device addressed
#            page = page addressed
#            data = data
#
########################################################################################

sub OWCOUNT_SetPage ($$$) {
  my ($hash, $page, $data) = @_;
  
  #-- set memory page/counter according to interface type
  my $interface= $hash->{IODev}->{TYPE};
  my $name    = $hash->{NAME};
  my $ret; 
  
  #-- check if memory usage has been disabled
  my $nomemory  = defined($attr{$name}{"nomemory"}) ? $attr{$name}{"nomemory"} : 0;
    
  if( $nomemory==0 ){
    #-- OWX interface
    if( $interface eq "OWX" ){
      $ret = OWXCOUNT_SetPage($hash,$page,$data);
    #-- OWFS interface
    }elsif( $interface eq "OWServer" ){
      $ret = OWFSCOUNT_SetPage($hash,$page,$data);
    #-- Unknown interface
    }else{
      return "OWCOUNT: SetPage with wrong IODev type $interface";
    }
    
    #-- process results
    if( defined($ret)  ){
      return "OWCOUNT: Could not set device $name, reason: ".$ret;
    }
  }else{
    if( $page==14 ){
      return OWCOUNT_store($hash,"OWCOUNT_".$name."_14.dat",$data);
    }elsif( $page==15 ){
      return OWCOUNT_store($hash,"OWCOUNT_".$name."_15.dat",$data);
    } else {
      return "OWCOUNT: file store with wrong page number";
    }
  } 
}

########################################################################################
#
# Store daily start value in a file
#
# Parameter hash, filename
#
########################################################################################

sub OWCOUNT_store($$$) {
  my ($hash,$filename,$data) = @_;
  
  my $name = $hash->{NAME};
  my $mp   = AttrVal("global", "modpath", ".");
  my $ret  = open(OWXFILE, "> $mp/FHEM/$filename" );
  if( $ret) {
    print OWXFILE $data;
    Log 1, "OWCOUNT_store: $name $data";
    close(OWXFILE);         
  } else {
    Log 1,"OWCOUNT_store: Cannot open $filename for writing!"; 
  }
  return undef;                   
}

########################################################################################
#
# Recall daily start value from a file
#
# Parameter hash,filename
#
########################################################################################

sub OWCOUNT_recall($$) {
  my ($hash,$filename) = @_;
  
  my $name= $hash->{NAME};
  my $mp  = AttrVal("global", "modpath", ".");
  my $ret = open(OWXFILE, "< $mp/FHEM/$filename" );
  if( $ret ){
    my $line = readline OWXFILE;
    close(OWXFILE);      
    return $line;
  }
  Log 1, "OWCOUNT_recall: Cannot open $filename for reading!";
  return 0;                 
}

########################################################################################
#
# OWCOUNT_Undef - Implements UndefFn function
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWCOUNT_Undef ($) {
  my ($hash) = @_;
  delete($modules{OWCOUNT}{defptr}{$hash->{OW_ID}});
  RemoveInternalTimer($hash);
  return undef;
}

########################################################################################
#
# The following subroutines in alphabetical order are only for a 1-Wire bus connected 
# via OWFS
#
# Prefix = OWFSCOUNT
#
########################################################################################
#
# OWFSCOUNT_GetPage - Get page from device
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWFSCOUNT_GetPage($$) {
  my ($hash,$page) = @_;
 
  #-- ID of the device
  my $owx_add = substr($hash->{ROM_ID},0,15);
  
  #-- hash of the busmaster
  my $master = $hash->{IODev};
  my $name   = $hash->{NAME};
  
  my $vval;
  my $strval;
  
  #=============== wrong value requested ===============================
  if( ($page<0) || ($page>15) ){
    return "wrong memory page requested";
  }     
  #-- get values - or shoud we rather get the uncached ones ?
  if( $page == 14) {
    $vval    = OWServer_Read($master,"/$owx_add/counters.A");
    $strval  = OWServer_Read($master,"/$owx_add/pages/page.14");
    
    return "no return from OWServer"
    if( (!defined($vval)) || (!defined($strval)) );
    
    return "empty return from OWServer"
    if( ($vval eq "") || ($strval eq "") );
    
    $hash->{owg_val}->[0]      = $vval;
    $hash->{owg_str}->[14]     = $strval;
    #-- parse float from midnight
    $strval =~ s/[^\d\.]+//g;
    $strval = 0.0 if(!defined($strval) or $strval !~ /^\d+\.?\d*$/);
    $strval = int($strval*100)/100;
    $hash->{owg_midnight}->[0] = $strval;
    
  }elsif( $page == 15) {
    $vval    = OWServer_Read($master,"/$owx_add/counters.B");
    $strval  = OWServer_Read($master,"/$owx_add/pages/page.15");
    
    return "no return from OWServer"
    if( (!defined($vval)) || (!defined($strval)) );
    
    return "empty return from OWServer"
    if( ($vval eq "") || ($strval eq "") );
    
    $hash->{owg_val}->[1]      = $vval;
    $hash->{owg_str}->[15]      = $strval;
    #-- parse float from midnight
    $strval =~ s/[^\d\.]+//g;
    $strval = 0.0 if(!defined($strval) or $strval !~ /^\d+\.\d*$/);
    $strval = int($strval*100)/100;
    $hash->{owg_midnight}->[1] = $strval;
  }else {
    $strval = OWServer_Read($master,"/$owx_add/pages/page.".$page);
    
    return "no return from OWServer"
    if( !defined($strval) );
    
    return "empty return from OWServer"
      if( $strval eq "" );
    $hash->{owg_str}->[$page] = $strval;
  }
  #-- and now from raw to formatted values 
  my $value = OWCOUNT_FormatValues($hash);
  Log 5, $value;
  return undef;
}

########################################################################################
#
# OWFSCOUNT_SetPage - Set page in device
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWFSCOUNT_SetPage($$$) {
  my ($hash,$page,$data) = @_;
  
  #-- ID of the device
  my $owx_add = substr($hash->{ROM_ID},0,15);
  
  #-- hash of the busmaster
  my $master = $hash->{IODev};
  my $name   = $hash->{NAME};
  
  #=============== wrong page requested ===============================
  if( ($page<0) || ($page>15) ){
    return "wrong memory page write attempt";
  } 
  OWServer_Write($master, "/$owx_add/pages/page.".$page,$data );
  return undef
}

########################################################################################
#
# The following subroutines in alphabetical order are only for a 1-Wire bus connected 
# directly to the FHEM server
#
# Prefix = OWXCOUNT
#
########################################################################################
#
# OWXCOUNT_GetPage - Get one memory page + counter from device
#
# Parameter hash = hash of device addressed
#           page = 0..15
#
########################################################################################

sub OWXCOUNT_GetPage($$) {
  my ($hash,$page) = @_;
  
  my ($select, $res, $res2, $res3, @data);
  
  #-- ID of the device, hash of the busmaster
  my $owx_dev = $hash->{ROM_ID};
  my $master  = $hash->{IODev};
  
  my ($i,$j,$k);

  #=============== wrong value requested ===============================
  if( ($page<0) || ($page>15) ){
    return "wrong memory page requested";
  } 
  #=============== get memory + counter ===============================
  #-- issue the match ROM command \x55 and the read memory + counter command
  #   \xA5 TA1 TA2 reading 40 data bytes and 2 CRC bytes
  my $ta2 = ($page*32) >> 8;
  my $ta1 = ($page*32) & 255;
  $select=sprintf("\xA5%c%c",$ta1,$ta2);   
  
  #-- asynchronous mode
  if( $hash->{ASYNC} ){
    #TODO: Parameters possibly wrong
    if (!OWX_Execute( $master, "getpage", 1, $owx_dev, "\x3C\x0F\x00\xFF\xFF", 0, 20 )) {
      return "not accessible for reading";
    }
    return OWX_AwaitExecuteResponse( $master, "getpage", $owx_dev );
  #-- synchronous mode
  } else {
    #-- reset the bus
    OWX_Reset($master);
    #-- reading 9 + 3 + 40 data bytes (32 byte memory, 4 byte counter + 4 byte zeroes) and 2 CRC bytes = 54 bytes
    $res=OWX_Complex($master,$owx_dev,$select,42);
    if( $res eq 0 ){
      return "device $owx_dev not accessible in reading page $page"; 
    }
    #-- process results
    if( length($res) < 54 ) {
      #Log 1, "OWXCOUNT: warning, have received ".length($res)." bytes in first step";
      #-- read the data in a second step
      $res.=OWX_Complex($master,"","",0);
      #-- process results
      if( length($res) < 54 ) {
        #Log 1, "OWXCOUNT: warning, have received ".length($res)." bytes in second step";  
        #-- read the data in a third step
        $res.=OWX_Complex($master,"","",0);
      }
    }  
    #-- reset the bus (needed to stop receiving data ?)
    #OWX_Reset($master);
    #-- for processing we need 45 bytes
    OWXCOUNT_BinValues($hash,$page,undef,undef,$owx_dev,undef,undef,substr($res,9));
  }
  return undef;
}

########################################################################################
#
# OWXCOUNT_BinValues - Process reading from one device - translate binary into raw
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWXCOUNT_BinValues($$$$$$$$) {
  my ($hash, $page, $success, $reset, $owx_dev, $data, $numread, $res) = @_;
  
  #-- unused are success, reset, data numread
  
  return undef unless (defined $page and $page ne "convert");
  
  my ($i,$j,$k,@data,$strval);
  my $change = 0;
  
  #-- process results
  @data=split(//,$res);
  return "invalid data length, ".int(@data)." instead of 45 bytes in three steps"
    if( int(@data) < 45);
  #return "invalid data"
  #  if (ord($data[17])<=0); 
  Log 1,"invalid CRC"
    if (OWX_CRC16(substr($res,0,43),$data[43],$data[44]) == 0);
  
  #-- first 3 command, next 32 are memory
  #-- memory part, treated as string
  $strval=substr($res,3,32);
  $hash->{owg_str}->[$page]=$strval;
  #-- counter part
  if( ($page == 14) || ($page == 15) ){
    @data=split(//,substr($res,35));
    if ( ($data[4] | $data[5] | $data[6] | $data[7]) ne "\x00" ){
      #Log 1, "device $owx_dev returns invalid data ".ord($data[4])." ".ord($data[5])." ".ord($data[6])." ".ord($data[7]);
      return "device $owx_dev returns invalid data";
    }
  
    my $value = (ord($data[3])<<24) + (ord($data[2])<<16) +(ord($data[1])<<8) + ord($data[0]);       
   
    if( $page == 14) {
      $hash->{owg_val}->[0] = $value;
      #-- parse float from midnight
      $strval =~ s/[^\d\.]+//g;
      $strval = 0.0 if(!defined($strval) or $strval !~ /^\d+\.\d*$/);
      $strval = int($strval*100)/100;
      $hash->{owg_midnight}->[0] = $strval;
    }elsif( $page == 15) {
      $hash->{owg_val}->[1] = $value;
      #-- parse float from midnight
      $strval =~ s/[^\d\.]+//g;
      $strval = 0.0 if(!defined($strval) or $strval !~ /^\d+\.\d*$/);
      $strval = int($strval*100)/100;
      $hash->{owg_midnight}->[1] = $strval;
    }
  }
  #-- and now from raw to formatted values 
  my $value = OWCOUNT_FormatValues($hash);
  Log 5, $value;
  return undef;
}

########################################################################################
#
# OWXCOUNT_SetPage - Set one memory page of device
#
# Parameter hash = hash of device addressed
#           page = "alarm" or "status"
#
########################################################################################

sub OWXCOUNT_SetPage($$$) {

  my ($hash,$page,$data) = @_;
  
  my ($select, $res, $res2, $res3);
  
  #-- ID of the device, hash of the busmaster
  my $owx_dev = $hash->{ROM_ID};
  my $master  = $hash->{IODev};
  
  #=============== wrong page requested ===============================
  if( ($page<0) || ($page>15) ){
    return "wrong memory page write attempt";
  } 
  #=============== set memory =========================================
  #-- issue the match ROM command \x55 and the write scratchpad command
  #   \x0F TA1 TA2 and the read scratchpad command reading 3 data bytes
  my $ta2 = ($page*32) >> 8;
  my $ta1 = ($page*32) & 255;
  #Log 1, "OWXCOUNT: setting page Nr. $ta2 $ta1";
  $select=sprintf("\x0F%c%c",$ta1,$ta2).$data;   
  #-- asynchronous mode
  if( $hash->{ASYNC} ){
    if (OWX_Execute( $master, "setpage", 1, $owx_dev, $select, 0, undef )) {
		return undef;
	} else {
    return "device $owx_dev not accessible for writing"; 
    }
  #-- synchronous mode
  } else {
    #-- reset the bus
    OWX_Reset($master);
    $res=OWX_Complex($master,$owx_dev,$select,0);
    if( $res eq 0 ){
      return "device $owx_dev not accessible in writing scratchpad"; 
    }
  }
  #-- issue the match ROM command \x55 and the read scratchpad command
  #   \xAA 
  #-- asynchronous mode
  if( $hash->{ASYNC} ){
    if (OWX_Execute( $master, "setpage", 1, $owx_dev, "\xAA", 0, undef )) {
		return undef;
	} else {
    return "device $owx_dev not accessible for writing"; 
    }
  #-- synchronous mode
  } else {
    #-- reset the bus
    OWX_Reset($master);
    #-- reading 9 + 4 + 16 bytes = 28 bytes
    # TODO: sometimes much less than 28
    $res=OWX_Complex($master,$owx_dev,"\xAA",28);
    if( length($res) < 13 ){
      return "device $owx_dev not accessible in reading scratchpad"; 
    }
  }
  #-- issue the match ROM command \x55 and the copy scratchpad command
  #   \x5A followed by 3 byte authentication code
  $select="\x5A".substr($res,10,3);
   #-- asynchronous mode
  if( $hash->{ASYNC} ){
    if (OWX_Execute( $master, "setpage", 1, $owx_dev, "\xAA", 0, undef )) {
		return undef;
	} else {
    return "device $owx_dev not accessible for writing"; 
    }
  #-- synchronous mode
  } else {
    #-- reset the bus
    OWX_Reset($master);
    $res=OWX_Complex($master,$owx_dev,$select,6);
  
    #-- process results
    if( $res eq 0 ){
      return "device $owx_dev not accessible for writing"; 
    }
  }
  return undef;
}

1;

=pod
=begin html

<a name="OWCOUNT"></a>
        <h3>OWCOUNT</h3>
        <p>FHEM module to commmunicate with 1-Wire Counter/RAM DS2423 or its emulation DS2423emu <br />
        <br />This 1-Wire module works with the OWX interface module or with the OWServer interface module
            (prerequisite: Add this module's name to the list of clients in OWServer).
            Please define an <a href="#OWX">OWX</a> device or <a href="#OWServer">OWServer</a> device first. <br/><p/>
        <br /><h4>Example</h4><br />
        <code>define OWC OWCOUNT 1D.CE780F000000 60</code>
        <br />
        <code>attr OWC AName Energie|energy</code>
        <br />
        <code>attr OWC AUnit kWh|kWh</code>
        <br />
        <code>attr OWC APeriod hour</code>
        <br />
        <code>attr OWC ARate Leistung|power</code>
        <br />
        <code>attr OWX_AMode daily</code>
        <br />
        <br />
        <a name="OWCOUNTdefine"></a>
        <h4>Define</h4>
        <p>
            <code>define &lt;name&gt; OWCOUNT [&lt;model&gt;] &lt;id&gt; [&lt;interval&gt;]</code> or <br/>
            <code>define &lt;name&gt; OWCOUNT &lt;fam&gt;.&lt;id&gt; [&lt;interval&gt;]</code> 
            <br /><br /> Define a 1-Wire counter.<br /><br /></p>
        <ul>
            <li>
                <code>[&lt;model&gt;]</code><br /> Defines the counter model (and thus 1-Wire family
                id), currently the following values are permitted: <ul>
                    <li>model DS2423 with family id 1D (default if the model parameter is
                        omitted)</li>
                    <li>model DS2423emu with family id 1D - works like DS2423 except that the internal memory is not used</li>
                </ul>
            </li>
            <li>
                <code>&lt;fam&gt;</code>
                <br />2-character unique family id, see above 
            </li>
            <li>
                <code>&lt;id&gt;</code>
                <br />12-character unique ROM id of the converter device without family id and CRC
                code </li>
            <li>
                <code>&lt;interval&gt;</code>
                <br />Measurement interval in seconds. The default is 300 seconds. </li>
        </ul>
        <br />
        <a name="OWCOUNTset"></a>
        <h4>Set</h4>
        <ul>
            <li><a name="owcount_interval">
                    <code>set &lt;name&gt; interval &lt;int&gt;</code></a><br /> Measurement
                interval in seconds. The default is 300 seconds. </li>
            <li><a name="owcount_memory">
                    <code>set &lt;name&gt; memory &lt;page&gt; &lt;string&gt;</code></a><br />Write 32 bytes to
                memory page 0..13 </li>
            <li><a name="owcount_midnight">
                    <code>set &lt;name&gt; midnight &lt;channel-name&gt; &lt;int&gt;</code></a><br />Write the
                day's starting value for counter &lt;channel&gt; (A, B or named channel, see
                below)</li>
        </ul>
        <br />
        <a name="OWCOUNTget"></a>
        <h4>Get</h4>
        <ul>
            <li><a name="owcount_id">
                    <code>get &lt;name&gt; id</code></a>
                <br /> Returns the full 1-Wire device id OW_FAMILY.ROM_ID.CRC </li>
            <li><a name="owcount_present">
                    <code>get &lt;name&gt; present</code>
                </a>
                <br /> Returns 1 if this 1-Wire device is present, otherwise 0. </li>
            <li><a name="owcount_interval2">
                    <code>get &lt;name&gt; interval</code></a><br />Returns measurement interval in
                seconds. </li>
            <li><a name="owcount_memory2">
                    <code>get &lt;name&gt; memory &lt;page&gt;</code></a><br />Obtain 32 bytes from
                memory page 0..13 </li>
            <li><a name="owcount_midnight2">
                    <code>get &lt;name&gt; midnight &lt;channel-name&gt;</code></a><br />Obtain the
                day's starting value for counter &lt;channel&gt; (A, B or named channel, see
                below)</li>
            <li><a name="owcount_month">
                    <code>get &lt;name&gt; month</code></a><br />Returns cumulated and averaged monthly value if mode=daily, otherwise last day's and averaged value </li>
            <li><a name="owcount_year">
                    <code>get &lt;name&gt; year</code></a><br />Returns cumulated and averaged yearly value if mode=daily, otherwise last months's and averaged value </li>
            <li><a name="owcount_raw">
                    <code>get &lt;name&gt; raw &lt;channel-name&gt;</code></a><br />Obtain the
                current raw value for counter &lt;channel&gt; (A, B or named channel, see below)</li>
            <li><a name="owcount_counters">
                    <code>get &lt;name&gt; counters</code></a><br />Obtain the current value both
                counters</li>
        </ul>
        <br />
        <a name="OWCOUNTattr"></a>
        <h4>Attributes</h4>
        <ul>
            <li><a name="owcount_logm"><code>attr &lt;name&gt; LogM
                        &lt;string&gt;</code></a>
                <br />device name (not file name) of monthly log file.</li>
                 <li><a name="owcount_logy"><code>attr &lt;name&gt; LogY
                        &lt;string&gt;</code></a>
                <br />device name (not file name) of yearly log file.</li>        
                 <li><a name="owcount_interval2">
                    <code>attr &lt;name&gt; interval &lt;int&gt;</code></a>
                    <br /> Measurement
                interval in seconds. The default is 300 seconds. </li>
                <li><a name="owcount_nomemory"><code>attr &lt;name&gt; nomemory
                        0|1</code></a>
                <br />when set to 1, midnight values will be stored in files instead of the internal memory.</li>
        </ul>
        <p>For each of the following attributes, the channel identification A,B may be used.</p>
        <ul>
            <li><a name="owcount_cname"><code>attr &lt;name&gt; &lt;channel&gt;Name
                        &lt;string&gt;|&lt;string&gt;</code></a>
                <br />name for the channel | a type description for the measured value. </li>
            <li><a name="owcount_cunit"><code>attr &lt;name&gt; &lt;channel&gt;Unit
                        &lt;string&gt;|&lt;string&gt;</code></a>
                <br />unit of measurement for this channel | its abbreviation. </li>
            <li><a name="owcount_crate"><code>attr &lt;name&gt; &lt;channel&gt;Rate
                        &lt;string&gt;|&lt;string&gt;</code></a>
                <br />name for the channel rate | a type description for the measured value. </li>
            <li><a name="owcount_coffset"><code>attr &lt;name&gt; &lt;channel&gt;Offset
                        &lt;float&gt;</code></a>
                <br />offset added to the reading in this channel. </li>
            <li><a name="owcount_cfactor"><code>attr &lt;name&gt; &lt;channel&gt;Factor
                        &lt;float&gt;</code></a>
                <br />factor multiplied to (reading+offset) in this channel. </li>
            <li><a name="owcount_cmode"><code>attr &lt;name&gt; &lt;channel&gt;Mode daily |
                        normal</code></a>
                <br />determines whether counter is nulled at start of day or running continuously </li>
            <li><a name="owcount_cperiod"><code>attr &lt;name&gt; &lt;channel&gt;Period hour(default) | minute |
                        second</code></a>
                <br />period for rate calculation </li>
            <li>Standard attributes <a href="#alias">alias</a>, <a href="#comment">comment</a>, <a
                    href="#event-on-update-reading">event-on-update-reading</a>, <a
                    href="#event-on-change-reading">event-on-change-reading</a>, <a
                    href="#stateFormat">stateFormat</a>, <a href="#room"
                    >room</a>, <a href="#eventMap">eventMap</a>, <a href="#loglevel">loglevel</a>,
                    <a href="#webCmd">webCmd</a></li>
        </ul>
        
=end html
=cut