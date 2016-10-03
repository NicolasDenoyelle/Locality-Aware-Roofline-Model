 #!/bin/bash 
#################################################################################################################################
# This is a script to plot results output by main benchmark.                                                                    #
# usage: plot_roofs.sh -o <output> -f <format> -t <filter(for input info col)> -i <input>                                       #
#                                                                                                                               #
# Author: Nicolas Denoyelle (nicolas.denoyelle@inria.fr)                                                                        #
# Date: 12/11/2015 (FR format)                                                                                                  #
# Version: 0.1                                                                                                                  #
#################################################################################################################################

usage(){
    printf "plot_roofs.sh <options...>\n\n"
    printf "options:\n"
    printf "\t-o <output file(pdf)>\n"
    printf "\t-f <perl regular expression to filter input rows. (Match is done on info column)> \n"
    printf "\t-b (if several bandwidths matches on a resource, the best only is kept)\n"
    printf "\t-i <input file given by roofline utility>\n"
    printf "\t-d <input data-file given by roofline library to plot applications on the roofline chart>\n"
    printf "\t-t <plot title>\n"
    printf "\t-p (per_thread: divide roofs' value by the number of threads)\n"
    printf "\t-v (plot validation points if any)\n"
    printf "\t-s (plot bandwidths deviation around median)\n" 
    exit
}

FILTER=".*"
TITLE="roofline chart"
BEST="FALSE"
SINGLE="FALSE"
VALIDATION="FALSE"
DEVIATION="FALSE"
#################################################################################################################################
## Parse options
while getopts :o:i:t:d:m:f:hbpvs opt; do
    case $opt in
	o) OUTPUT=$OPTARG;;
	d) DATA=$OPTARG;;
	m) METHOD=$OPTARG;;
	i) INPUT=$OPTARG;;
	f) FILTER="$OPTARG";;
	t) TITLE="$OPTARG";;
	p) SINGLE="TRUE";;
	v) VALIDATION="TRUE";;
	s) DEVIATION="TRUE";;
	h) usage;;
	:) echo "Option -$OPTARG requires an argument."; exit;;
    esac
done

## Check arguments output if not
if [ -z "$OUTPUT" ]; then
    OUTPUT=$PWD/roofline_chart.pdf
fi

if [ -z "$INPUT" ]; then
    echo "Input file required"
    usage
fi

output_R(){
    R --vanilla --silent --slave <<EOF
#Columns id
dobj        = 1;    #The obj column id
dthroughput = 2;    #The instruction throughput
dbandwidth  = 3;    #The bandwidth column id
dgflops     = 4;    #The gflop/s column id
doi         = 5;    #The oi column id
dthreads    = 6;    #The number of threads
dtype       = 7;    #The info column id

filter <- function(df, col){
  subset(df, grepl("$FILTER", df[,col], perl=TRUE))
}

#load data
d = filter(read.table("$INPUT",header=TRUE, stringsAsFactors=FALSE), dtype)

#get fpeaks
fpeak_samples = d[d[,dbandwidth]==0,]
fpeak_types = unique(fpeak_samples[,dtype])
fpeaks = data.frame(type=character(0), performance=numeric(0), sd=numeric(0), nthreads=integer(0), stringsAsFactors=FALSE)
for(i in 1:length(fpeak_types)){
  ftype = fpeak_types[i]
  fpeak_s = fpeak_samples[fpeak_samples[,dtype]==ftype,]
  fpeaks[i,1] = ftype
  fpeaks[i,2] = median(fpeak_s[,dgflops])
  fpeaks[i,3] = sd(fpeak_s[,dgflops])
  fpeaks[i,4] = fpeak_s[1,dthreads]
}
fpeak_max = as.numeric(max(fpeaks[,2])) #the top peak performance

#get bandwidths
bandwidths_samples = d[d[,dgflops]==0,]
bandwidths_types = unique(bandwidths_samples[,c(dobj,dtype)])
bandwidths = data.frame(obj=character(0), type=character(0), bandwidth=numeric(0), sd=numeric(0), nthreads=integer(0), stringsAsFactors=FALSE)
for(i in 1:nrow(bandwidths_types)){
  bobj = bandwidths_types[i,1]
  btype = bandwidths_types[i,2]
  bandwidths_s = bandwidths_samples[bandwidths_samples[,dtype]==btype,]
  bandwidths_s = bandwidths_s[bandwidths_s[,dobj]==bobj,]
  bandwidths[i,1] = bobj
  bandwidths[i,2] = btype
  bandwidths[i,3] = median(bandwidths_s[,dbandwidth])
  bandwidths[i,4] = sd(bandwidths_s[,dbandwidth])
  bandwidths[i,5] = bandwidths_s[1,dthreads]
}
#check if results have to be presented per thread
if($SINGLE){
  for( i in 1: nrow(fpeaks) ){fpeaks[i,2] = as.numeric(fpeaks[i,2])/as.numeric(fpeaks[i,4])}
  for( i in 1: nrow(bandwidths) ){bandwidths[i,3] = as.numeric(bandwidths[i,3])/as.numeric(bandwidths[i,5])}
}

print(fpeaks)
print(bandwidths)

#Logarithmic sequence of points
lseq <- function(from=1, to=100000, length.out = 6) {
  exp(seq(log(from), log(to), length.out = length.out))
}

# axes
xmin = 2^-8; xmax = 2^6; xlim = c(xmin,xmax)
xticks = lseq(xmin,xmax,log(xmax/xmin,base=2) + 1)
xlabels = sapply(xticks, function(i) as.expression(bquote(2^ .(round(log(i,base=2))))))
oi = lseq(xmin,xmax,500)

fpeak_max = as.numeric(max(fpeaks[,2])) #the top peak performance
ymax = 10^ceiling(log10(fpeak_max)); ymin = ymax/10000; ylim = c(ymin,ymax)
yticks = lseq(ymin, ymax, log10(ymax/ymin))
ylabels = sapply(yticks, function(i) as.expression(bquote(10^ .(round(log10(i))))))

pdf("$OUTPUT", family = "Helvetica", title="roofline chart", width=10, height=5)

#plot bandwidths roofs
par(ann=FALSE)
plot_bandwidth <- function(val, sd = 0, color = 1){
  gflops     = sapply(oi*val, min, fpeak_max)
  plot(oi, gflops, lty=1, type="l", log="xy", axes=FALSE, xlim=xlim, ylim=ylim, col=color, panel.first=abline(h=yticks, v=xticks,col = "darkgray", lty = 3))
  par(new=TRUE);
  if($DEVIATION){
    xdev=sd*sd*sqrt(1+(1/(val*val)))
    coord.x = c(xmin*(1-xdev), fpeak_max/val*(1 - xdev), fpeak_max/val*(1 + xdev), xmin*(1+xdev))
    coord.y = c(xmin*val, fpeak_max, fpeak_max, xmin*val)
    polygon(coord.x,coord.y,col=adjustcolor(i,alpha.f=.25), lty="blank")
    par(new=TRUE);
  }
}


for(i in 1:nrow(bandwidths)){
  plot_bandwidth(as.numeric(bandwidths[i,3]), sd = as.numeric(bandwidths[i,4]), col=i);
}

#plot fpeak roofs
abline(h = fpeaks[,2], lty=3, col=1, lwd=2);

for (i in 1:nrow(fpeaks)){
  j=1; flops = as.numeric(fpeaks[i,2])

  while(j <= length(yticks)){
    if( (yticks[j]<2*flops) && (yticks[j]>flops) ){
      yticks = yticks[-c(j)]
      ylabels = ylabels[-c(j)]
      j = 1
    }
    else if( (yticks[j]*2>flops) && (yticks[j]<flops) ){
      yticks = yticks[-c(j)]
      ylabels = ylabels[-c(j)]
      j = 1
    }
    j = j+1
  }
}
yticks = c(yticks, fpeaks[,2])
ylabels = c(ylabels, sprintf("%.2f", as.numeric(fpeaks[,2])))
axis(2, labels = fpeaks[,1], at = fpeaks[,2], las=1, tick=FALSE, pos=xmin, padj=0, hadj=0)

#plot validation points
if($VALIDATION){
  points = subset(d, d[,dgflops]!=0 & d[,dbandwidth]!=0)
  for(i in 1:nrow(bandwidths)){
    valid = subset(points, points[,dtype]==bandwidths[i,2] & points[,dobj]==bandwidths[i,1])
    if($SINGLE){
      valid[,dgflops] = valid[,dgflops]/valid[,dthreads]
    }
    if(!$DEVIATION){
      ois = unique(valid[,doi])
      for(oi in ois){
        points(oi, median(subset(valid[,dgflops], valid[,doi] == oi)), asp=1, pch=i, col=i)
      }
    } else {
      points(valid[,doi], valid[,dgflops], asp=1, pch=i, col=i)
    }
    par(new=TRUE);
  }
}

#draw axes, title and legend
axis(1, at=xticks, labels=xlabels)
axis(2, at=yticks, labels=ylabels, las=1)
title(main = "$TITLE", xlab="Flops/Byte", ylab="GFlops/s")
legend("bottomright", legend=paste(bandwidths[,1], paste(bandwidths[,2], sprintf("%.2f", as.numeric(bandwidths[,3])), sep="="), "GB/s", sep=" "), cex=.7, lty=1, col=1:nrow(bandwidths), bg="white")

#plot MISC points
if("$DATA" != ""){
  dnano   = 1
  dbyte   = 2
  dflop   = 3
  dthread = 4
  dtype   = 5
  dinfo   = 6

  misc = read.table("$DATA",header=TRUE)
  misc = filter(misc, dtype)
  misc = filter(misc, dinfo)
  misc["oi"] = ifelse(misc[,dbyte]==0, NA, as.numeric(misc[,dflop])/as.numeric(misc[,dbyte]))
  misc["perf"] = ifelse(misc[,dnano]==0, NA, as.numeric(misc[,dflop])/as.numeric(misc[,dnano]))
  types = unique(misc[,c(dtype, dinfo)])
  legend_range = seq(nrow(bandwidths)+1, nrow(bandwidths)+nrow(types), by=1)
<<<<<<< HEAD
  for(i in 1:nrow(types)){
    points = subset(misc, misc[,dtype] == types[i,1] & misc[,dinfo] == types[i,2])
    points(points[,"oi"], points[,"perf"], asp=1, pch=legend_range[i], col=legend_range[i])
    par(new=TRUE);
  }
=======
  medians = data.frame(arithmetic_intensity=numeric(0), performance=numeric(0), bandwidth=numeric(0), type=character(0), id=character(0), stringsAsFactors=FALSE)
  for(i in 1:nrow(types)){
    points      = subset(misc, misc[,dtype] == types[i,1] & misc[,dinfo] == types[i,2])
    points      = points[order(points[,"perf"]),]
    median      = points[nrow(points)/2,"perf"]
    oi          = points[nrow(points)/2,"oi"]
    bandwidth   = points[nrow(points)/2,dbyte]/points[nrow(points)/2,dnano]
    medians[i,] = c(oi,median,bandwidth,as.character(types[i,1]),as.character(types[i,2]))
    if(!$DEVIATION){points(oi, median, asp=1, pch=legend_range[i], col=legend_range[i])} 
    else{points(points[,"oi"], points[,"perf"], asp=1, pch=legend_range[i], col=legend_range[i])}
    par(new=TRUE);
  }
  print(medians)
>>>>>>> master
  legend("topright", legend=apply(types, 1, function(t){paste(t[1], t[2], sep=" ")}), cex=.7, col=legend_range, pch=legend_range, bg="white")
}

box()

#output
graphics.off()
EOF
}


#################################################################################################################################
## output
output_R

