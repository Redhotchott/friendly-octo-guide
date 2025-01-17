#Michael Modified 
# trying to use previous ab values to get the next ones to speed up run time. 
rm(list=ls())

load("predictors.Rdata")
library('sn')
library('fields')
param<-read.table('MichaelAB.txt')
# dates:        all dates for which data are available
# stations:     names of all stations for which data are available
# lat, lon:     longitude and latitude coordinate for each of these stations
# elev:         station elevation (m)
# ptype:        all cases where one of the four precipitation types of interest was reported
# Twb.prof:     the corresponding vertical profiles of wetbulb temperature (0m to 3000m above the surface in steps of 100m)
# station.ind:  for each case, the index of the station where it was reported
# date.ind:     for each case, the index of the date on which it was reported

# Define the function for a leave-one-out cross validation estimate of the regularization parameter in RDA

CVscore.RDA <- function(param, profiles, ptype, mu.K, e.K, v.K, prob.cl)  {
  a <- param[1]
  b <- param[2]
  
  if (a<0 | b<0) return(0)
  
  d <- nrow(mu.K)
  K <- ncol(mu.K)
  n <- length(ptype)
  
  n.K <- table(ptype)
  
  dim(profiles) <- c(dim(profiles),1)
  
  # Compute cross validated likelihoods and class probabilities
  likelihood <- matrix(NA,K,1)
  prob.rda <- matrix(NA,n,K)
  
  for (i in 1:n)  {
    if (any(is.na(profiles[i,,])) | is.na(ptype[i])) next
    X <- as.matrix(profiles[i,,])
    
    for (k in 1:K)  {
      if (ptype[i]==k)  {
        mu.k.cv <- (n.K[k]*mu.K[,k]-apply(X,1,sum))/(n.K[k]-1)
        proj.R <- crossprod(v.K[,,k],sweep(X,1,mu.k.cv,"-"))
        e.reg.cv <- a*((n.K[k]-1)/(n.K[k]-2))*e.K[,k]+b
        qdr.tmp <- sum((proj.R/sqrt(e.reg.cv))^2)
        gam <- a*(n.K[k]-1)/(n.K[k]*(n.K[k]-2))
        quadratic.cv <- qdr.tmp / (1-gam*qdr.tmp)
        logdet.cv <- sum(log(e.reg.cv) + log1p(-gam*qdr.tmp))
        likelihood[k,] <- exp(-0.5*(logdet.cv+quadratic.cv))
      } else  {
        proj.R <- crossprod(v.K[,,k],sweep(X,1,mu.K[,k],"-"))
        quadratic <- apply((proj.R/sqrt(a*e.K[,k]+b))^2,2,sum)
        logdet <- sum(log(a*e.K[,k]+b))
        likelihood[k,] <- exp(-0.5*(logdet+quadratic))
      }
    }
    prob.unnormalized <- sweep(likelihood,1,(prob.cl[i,]+0.001),"*")
    prob.rda.members <- sweep(prob.unnormalized,2,apply(prob.unnormalized,2,sum),"/")
    prob.rda[i,] <-  apply(prob.rda.members,1,mean)
  }
  
  # Calculate Brier skill scores for every category
  BS.rda <- BS.climo <- rep(0,K)
  use <- apply(!is.na(prob.rda),1,any)
  
  for (k in 1:K)  {
    BS.rda[k] <- sum((prob.rda[use,k]-1*(ptype==k))^2,na.rm=TRUE)
    BS.climo[k] <- sum((prob.cl[use,k]-1*(ptype==k))^2,na.rm=TRUE)
  }
  return( -sum(1-BS.rda/BS.climo) )
}

d <- 16      # I only consider the wetbulb temperatures up to 1500m as predictors

K <- length(unique(ptype))
years <- unique(dates%/%1000000)
ptype.string <- ptype

# Re-code precip types into integers 1-4 
ptype <- integer(length(ptype.string))
ptype[ptype.string=="SN"]   <- 1
ptype[ptype.string=="RA"]   <- 2
ptype[ptype.string=="IP"]   <- 3
ptype[ptype.string=="FZRA"] <- 4

month.ind <- (dates[date.ind] %/% 10000) %% 100

# climatological frequencies of each precip. type at each station

prob.cl <- array(dim=c(12,length(stations),K))
prob.fcst.climo <- matrix(NA,length(station.ind),4)

for (st in 1:length(stations)) {
  for (mm in 1:12)  {
    subset.ind <- month.ind==mm & station.ind==st
    if (!any(subset.ind)) next
    n.ptype <- tabulate(ptype[subset.ind], nbins=4)
    n.all <- sum(n.ptype)
    #		prob.cl[mm,st,] <- (n.ptype+0.001*n.all) / ((1+K*0.001)*n.all)
    prob.cl[mm,st,] <- n.ptype / n.all
    prob.fcst.climo[subset.ind,] <- matrix(prob.cl[mm,st,],sum(subset.ind),4,byrow=TRUE)
  }
  mm.na <- which(is.na(prob.cl[,st,1]) & (1:12) %in% unique(month.ind))
  for (mm in mm.na)  {
    prob.cl[mm,st,] <- apply(prob.cl[,st,],2,mean,na.rm=TRUE)
  }
}

prob.fcst.rda <- matrix(NA,length(ptype),K)

for (iyear in 1:12)  {   # loop over the 12 cool seasons 2001-2012, use the previous 5 cool seasons for training
  
  train.season <- years[iyear+(0:4)]
  verif.season <- years[iyear+5]
  cat(paste("Processing cool season", verif.season,"\n"))
  
  dates.yy <- dates %/% 1000000
  dates.mm <- (dates %/% 10000) %% 100
  
  train.subset <- which((dates.yy%in%train.season & dates.mm>8) | (dates.yy%in%(train.season+1) & dates.mm<6))
  train.ind <- which(date.ind %in% train.subset)
  n.train <- length(train.ind)
  verif.subset <- c(which(dates.yy==verif.season & dates.mm>8),which(dates.yy==(verif.season+1) & dates.mm<6))
  verif.ind <- which(date.ind %in% verif.subset)
  
  Twb.prof.train <- Twb.prof[train.ind,1:d]
  ptype.train <- ptype[train.ind]
  prob.fcst.climo.train <- prob.fcst.climo[train.ind,]
  
  
  # Calculate empirical means and covariances for each class
  mu.K <- matrix(NA,d,K)
  Sigma.K <- array(dim=c(d,d,K))
  for (k in 1:K)  {
    mu.K[,k] <- apply(Twb.prof.train[ptype.train==k,],2,mean,na.rm=TRUE)
    Sigma.K[,,k] <- cov(Twb.prof.train[ptype.train==k,], use="complete.obs")
  }
  
  Sigma.K.reg <- array(dim=c(d,d,K))
  
  for (k in 1:K)  {
    Sigma.K.reg[,,k] <- param[iyear,1]*Sigma.K[,,k]+param[iyear,2]*diag(d)
  }
  
  # Compute eigenvalue decomposition of Sigma.K
  e.K <- array(dim=c(d,K))
  v.K <- array(dim=c(d,d,K))
  for (k in 1:K)  {
    evd.K <- eigen(Sigma.K[,,k])
    e.K[,k] <- evd.K$val
    v.K[,,k] <- evd.K$vec
  }
  
  verif.ind.ss <- verif.ind[!is.na(ptype[verif.ind])]
  likelihood <- matrix(NA,K,1)
  
  # Calculate classification probabilities for verification cases using the fitted regularization parameters
  for (i in verif.ind.ss)  {
    X <- matrix(Twb.prof[i,1:d],d,1)
    for (k in 1:K)  {
      proj.R <- crossprod(v.K[,,k],sweep(X,1,mu.K[,k],"-"))
      quadratic <- apply((proj.R/sqrt(param[iyear,1]*e.K[,k]+param[iyear,2]))^2,2,sum)
      logdet <- sum(log(param[iyear,1]*e.K[,k]+param[iyear,2]))
      likelihood[k,] <- exp(-0.5*(logdet+quadratic))
    }
    prob.unnormalized <- sweep(likelihood,1,(prob.fcst.climo[i,]+0.001),"*")
    prob.rda.members <- sweep(prob.unnormalized,2,apply(prob.unnormalized,2,sum),"/")
    prob.fcst.rda[i,] <- apply(prob.rda.members,1,mean)
  }
}
classes<-c('SN', 'RA', 'IP', 'FZRA')
par(mfrow=c(2,2))
for(i in 1:4){
image.plot(1:16,1:16, t(Sigma.K[16:1,,i]), zlim=c(0,60),main=paste(classes[i],' Covariance - Unreg'), xaxt="n",yaxt="n",xlab="",ylab="")
}
par(mfrow=c(2,2))
for(i in 1:4){
  image.plot(1:16,1:16, t(Sigma.K.reg[16:1,,i]), zlim=c(0,60),main=paste(classes[i],' Covariance - Reg'), xaxt="n",yaxt="n",xlab="",ylab="")
}
test=complete.cases(prob.fcst.rda)
prob.fcst=prob.fcst.rda[test,]
# write.table(test, 'testnooptim.txt')
# write.table(prob.fcst, 'probfcstnooptim.txt')
# write.table(prob.fcst.rda, 'probfcstrdanooptim.txt')

write.table(test, 'testnooptim.txt')
write.table(prob.fcst, 'probfcstnooptim.txt')
write.table(prob.fcst.rda, 'probfcstrdanooptim.txt')
# Calculate Brier skill scores for every category

BS.rda <- BS.climo <- rep(0,K)
use <- apply(!is.na(prob.fcst.rda),1,any)

for (k in 1:K)  {
  BS.rda[k] <- mean((prob.fcst.rda[use,k]-1*(ptype[use]==k))^2,na.rm=TRUE)
  BS.climo[k] <- mean((prob.fcst.climo[use,k]-1*(ptype[use]==k))^2,na.rm=TRUE)
}

BS.rda
BS.scores.mich<-round( 1-c(BS.rda,sum(BS.rda))/c(BS.climo,sum(BS.climo)), 3)
# write.table(BS.scores.mich, 'BSMICHAEL')
BS.climo
sum(BS.climo)

BS.scores.mich<-round( 1-c(BS.rda,sum(BS.rda))/c(BS.climo,sum(BS.climo)), 3)
write.table(BS.scores.mich, 'BSMICHAEL')

# Verification: Reliability diagrams

#source("~/Desktop/Mandy/reliability-diagram.r")
breaks <- round(seq(-0.025,1.025,0.05),3)

n <- x <- y <- matrix(0,K,length(breaks)-1)
use <- apply(!is.na(prob.fcst.rda),1,all)

for (k in 1:K)  {
  I <- outer(prob.fcst.rda[use,k], breaks[-length(breaks)], ">=") & outer(prob.fcst.rda[use,k], breaks[-1], "<")
  n[k,] <- apply(I, 2, sum)
  x[k,] <- apply(I*prob.fcst.rda[use,k], 2, sum, na.rm=TRUE)
  y[k,] <- apply(I*(ptype[use]==k), 2, sum, na.rm=TRUE)
}

# write.table(n, 'ntable.txt')
# write.table(x, 'xtable.txt')
# write.table(y, 'ytable.txt')
write.table(n, 'ntable.txt')
write.table(x, 'xtable.txt')
write.table(y, 'ytable.txt')

#order of legend SN, RA, IP, FZRA
par(mfrow=c(1,1))
colors<-c('red','green', 'blue', 'yellow')
plot(x[1,]/n[1,],y[1,]/n[1,], type='o',  main="Reliability Plot", col='red', xlab="Forecasted Probability", ylab="Observed Probability", xlim=c(0,1), ylim=c(0,1))
#abline(0,1)
for(i in 2:4){
  lines(x[i,]/n[i,],y[i,]/n[i,], type='o',col=colors[i])
}
abline(0,1,ylim=c(0,1))
legend(0,0.9,legend=c("SN","RA","IP","FZRA"),col=c('red', 'green', 'blue', 'yellow'),pch = 'o')

titles = c("Snow","Rain","Ice Pellets", "Freezing Rain")
for(i in 18:21){n[3,i]<- 0.001 }

par(mfrow=c(2,2))
for(i in 1:4){

barplot(log(n[i,]),col=colors[i],main=titles[i], ylim=c(0,15))

barplot(log(n[i,]),col=colors[i],main=titles[i])

}
#legend(col=c('red', 'green', 'blue', 'yellow'))

# for (k in 1:K)  {
#   I <- outer(prob.fcst.rda[use,k], breaks[-length(breaks)], ">=") & outer(prob.fcst.rda[use,k], breaks[-1], "<")
#   n[k,] <- apply(I, 2, sum)
#   x[k,] <- apply(I*prob.fcst.rda[use,k], 2, sum, na.rm=TRUE)
#   y[k,] <- apply(I*(ptype[use]==k), 2, sum, na.rm=TRUE)
# }
# 
# plot(x[1,]/n[1,],y[1,]/n[1,],xlim=c(0,1),ylim=c(0,1))
# abline(0,1)
# barplot(log(n[1,]))

# png("~/Desktop/Mandy/reliability.png", width=2100, height=2100, res=300)
# plot.reliability (n, x, y)
# dev.off()

# Now: calculate and count the correctly classified cases

rda.all <- rda.correct <- rep(0,K)

rda.class <- apply(prob.fcst.rda[use,],1,which.max)
rda.all <- table(rda.class)
rda.correct <- table(rda.class[rda.class==ptype[use]])

cbind(c(rda.all,sum(rda.all)),c(rda.correct,sum(rda.correct)))

round(rda.correct/rda.all,3)*100    # fractions