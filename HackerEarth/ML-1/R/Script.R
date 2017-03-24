library(h2o)
library(corrplot)
library(stringr)
library(data.table)
library(tm)

data = read.csv("../data/train_indessa.csv")
rows = dim(data)[1]


## Correlated variables
num_col = colnames(data)[sapply(train, is.numeric)]
num_col = num_col[!(num_col %in% c("member_id","loan_status"))]

corrplot(cor(data[,num_col]), method = "number")

drops = c("funded_amnt","funded_amnt_inv","collection_recovery_fee")
data = data[, !(names(data) %in% drops)]



## Helper Functions
# to display variables in memory by size
sort( sapply(ls(),function(x){object.size(get(x))})) 

getNAs=function(column){
  print(sum(is.na(column)))
}

getUniqueEntries=function(column){
  print(unique(column))
}

getPivotTable = function(variable){
  pivot_1 = aggregate(loan_status~variable, data, FUN=sum)
  pivot_2 = aggregate(loan_status~variable, data, FUN=length)
  pivot_2["defaults"] = pivot_1["loan_status"]
  pivot_2["avg"] = pivot_2["defaults"]/pivot_2["loan_status"]
  pivot_2
}

getAccuracy=function(predictions, actual){
  predictions = ifelse(predictions > 0.5,1,0)
  error_percent = mean(predictions != actual)
  print(paste('Accuracy',1-error_percent))
}

getPivotTable = function(variable){
  pivot_1 = aggregate(loan_status~variable, data, FUN=sum)
  pivot_2 = aggregate(loan_status~variable, data, FUN=length)
  pivot_2["defaults"] = pivot_1["loan_status"]
  pivot_2["avg"] = pivot_2["defaults"]/pivot_2["loan_status"]
  pivot_2
}

trim = function (x) gsub("^\\s+|\\s+$", "", x)

getNFrequentWords=function(var_col, var_str, rows_to_use=4000, defaulter=TRUE){

  non_empty_rows = var_col != ""
  
  if(defaulter){
    defaulters_rows = data$loan_status == 1
    df = data[ non_empty_rows&defaulters_rows, c(var_str,"loan_status")]
  }else{
    non_defaulters_rows = data$loan_status == 0
    df = data[ non_empty_rows&non_defaulters_rows, c(var_str, "loan_status")]
  }
  print("Converting to Corpus")
  x_cor = Corpus(DataframeSource(df[1:row_to_use,]))
  print("Applying transformations")
  x_cor = tm_map(x_cor, removeWords, stopwords("english")) 
  x_cor = tm_map(x_cor, removePunctuation) 
  x_cor = tm_map(x_cor, removeNumbers) 
  x_cor = tm_map(x_cor, stripWhitespace) 
  print("Converting to DocumentTermMatrix")
  dtm =  DocumentTermMatrix(x_cor)
  print("Calculating Frequencies")
  findFreqTerms(dtm, row_to_use/4)
}


### Feature engineering ###
# loan_amt added
sum(is.na(data$loan_amnt))

# funded_amnt - highly corelated - removed

# funded_amnt_inv - highly corelated - removed

# term - added
data$term = as.numeric(unlist(str_extract_all(string = data$term,pattern = "\\d+")))

# batch_enrolled : 105 levels !!! : ???

# int_rate : sightly correlated : ???

# grade added

# sub-garde : added

# emp_length : added : do we need to convert them into numeric ???
levels(data$emp_length) = c(levels(data$emp_length), -1:11)
data$emp_length [data$emp_length=="n/a"] = 11
data$emp_length [data$emp_length=="< 1 year"] = 0
data$emp_length = as.numeric(unlist(str_extract_all(string = data$emp_length,pattern = "\\d+")))
data$emp_length [data$emp_length==11] = -1
data$emp_length = factor(data$emp_length)

# home_ownership : added

# annual_inc <<<
data[is.na(data$annual_inc),"annual_inc"] = 0
data$annual_inc = log(data$annual_inc+10)

# verification_status : added

# pymnt_plan : not adding : almost everything is n

# desc 
trim = function (x) gsub("^\\s+|\\s+$", "", x)
data$desc1 = trim(data$desc)
non_empty_rows = data$desc1 != ""
defaulters_rows = data$loan_status == 1
non_defaulters_rows = data$loan_status == 0
defaulters = data[ non_empty_rows&defaulters_rows, c("desc1","loan_status")]
non_defaulters = data[ non_empty_rows&non_defaulters_rows, c("desc1", "loan_status")]

row_to_use = 4000
x_cor = Corpus(DataframeSource(non_defaulters[1:row_to_use,]))
x_cor = tm_map(x_cor, removeWords, stopwords("english")) 
x_cor = tm_map(x_cor, removePunctuation) 
x_cor = tm_map(x_cor, removeNumbers) 
x_cor = tm_map(x_cor, stripWhitespace) 
dtm =  DocumentTermMatrix(x_cor)
findFreqTerms(dtm, row_to_use/4)


# delinq_2yrs
sum(is.na(data$delinq_2yrs))
data[is.na(data$delinq_2yrs),"delinq_2yrs"] = 0

# pub_rec
sum(is.na(data$pub_rec))
data[is.na(data$pub_rec),"pub_rec"] = 0



### Train Test Split ###
x = c("loan_amnt", "term", "grade", "sub_grade", "emp_length", "home_ownership", "annual_inc", 
      "verification_status",
      "delinq_2yrs", "pub_rec")
y = c("loan_status")
x_y = c("member_id",x,y)
train_rows = sample(1:rows, 0.75*rows, replace=F)
train = data[train_rows, x_y]
test = data[-train_rows, x_y]



### h2o initialization ###
h2o.init(nthreads = -1,max_mem_size = "2G") 

h2o_train = as.h2o(train)
h2o_test = as.h2o(test)
h2o_train$loan_status = h2o.asfactor(h2o_train$loan_status)


## validation strategy
xd = h2o.splitFrame(h2o_train,ratios = 0.6)
split_val = xd[[2]]


## Training model
gbm_clf <- h2o.gbm(x = x
                   ,y = y
                   ,training_frame = h2o_train
                   ,validation_frame = split_val
                   #,ignore_const_cols = TRUE
                   ,ntrees = 100
                   ,max_depth = 10
                   ,stopping_rounds = 5
                   ,model_id = "gbm_model"
                   ,stopping_metric = "AUC"
                   ,learn_rate = 0.05
                   ,col_sample_rate_per_tree = 0.8
                   ,sample_rate = 0.8
                   ,learn_rate_annealing = 0.99
)

gbm_clf_pred = as.data.table(h2o.predict(gbm_clf, h2o_test))
predictions = gbm_clf_pred$p1
getAccuracy(predictions, test$loan_status)



### REAL TEST ###
real_test = read.csv("../data/test_indessa.csv")

# tranformations
real_test[is.na(real_test$delinq_2yrs),"delinq_2yrs"] = 0
real_test[is.na(real_test$pub_rec),"pub_rec"] = 0
real_test$term = as.numeric(unlist(str_extract_all(string = real_test$term,pattern = "\\d+")))

levels(real_test$emp_length) = c(levels(real_test$emp_length), -1:11)
real_test$emp_length [real_test$emp_length=="n/a"] = 11
real_test$emp_length [real_test$emp_length=="< 1 year"] = 0
real_test$emp_length = as.numeric(unlist(str_extract_all(string = real_test$emp_length,pattern = "\\d+")))
real_test$emp_length [real_test$emp_length==11] = -1
real_test$emp_length = factor(real_test$emp_length)


real_test_h2o = as.h2o(real_test)
gbm_clf_pred = as.data.table(h2o.predict(gbm_clf, real_test_h2o))

to_write = data.frame("member_id"=real_test$member_id, "loan_status"=gbm_clf_pred$p1)
write.csv(to_write, file="gbm_9v.csv", row.names = FALSE, quote = FALSE)

