#! /bin/bash
### helper script for Odoo instances

help_message="
Usage: $0 options [extra odoo cli parameters] [--dry]

Options (if more given, last one applied):

  run			  - start odoo instance. If config given, no parameter added
  run-config		  - start with config file. Extra arguments forwarded to odoo.
  restart		  - alias to 'stop restart'
  systemd-start		  - start instance with config file and wait
  stop		 	  - stop odoo instance
  init	      		  - init db
  save			  - save config file to <instance_dir>/odoo.conf
  shell			  - start odoo shell
  update		  - update module
  scaffold		  - shortcut to odoo scaffold
  dbdump		  - save db dump to <instance_dir>/dump.sql
  dbrestore		  - restore db from <instance_dir>/dump.sql
  dropdb		  - drop db
  link/unlink		  - link/unlink module to instance custom addons path
  less			  - browse log file with less utility
  	
Odoo parameters after automatically added --stop-after-init and restart Odoo instance if it was running:
  --init
  --save

Misc options:
  restart		  - restart after execution
  --dry|-d		  - dry run, write command to stdout (implies --verbose)
  --verbose|-v		  - echo command
  --help|-h		  - print this message
"

## read options
args_extra=()
for a in $*; do
    case $a in
	run|run-config|systemd-start|stop|init|save|shell|update|scaffold|dbdump|dbrestore|dropdb|psql|link|unlink|less)
	    mode=$a
	    ;;
	restart)
	    if [ -z $mode ]; then
		mode="restart"
	    else
		restart=1
	    fi
	    ;;
	-c|--config*)
	    config=1
	    args_extra+=($a)
	    ;;
	--dry|-d)
	    dry=1
	    verbose=1
	    ;;
	--verbose|-v)
	    verbose=1
	    ;;
	--init*|-i|--update*|-u|--save*|-s)
	    args_extra+=("--stop-after-init" $a)
	    ;;
	--help|-h)
	    echo "$help_message"
	    exit 0
	    ;;
	*)
	    args_extra+=($a)
    esac
done

if [ -z $mode ]; then
    echo "$help_message"
    exit 1
fi

## dirs
WD="/opt/odoo"
ODOO="${WD}/odoo"
CONF_DIR="${WD}/config"
DATA_DIR="${WD}/data"
LOG_FILE="${WD}/log/${INST}.log"
RUNTIME_DIR="${WD}/tmp"
PID_FILE="${RUNTIME_DIR}/pid"

## system arguments
args_sys=(
    "--pidfile='${PID_FILE}'"
    "--logfile='${LOG_FILE}'"
)

## source instance specific arguments ($args_inst) and vars
INST_FILE="${WD}/config/odoo-vars-inst.sh"
if [ -f ${INST_FILE} ]; then
    [[ $verbose ]] && echo "Loading instance settings from ${INST_FILE}..."
    source "${INST_FILE}"
else
    echo -e "Couldn't find instance settings file!\n"
    exit 1
fi

## merge odoo parameters
ARGS="${args_sys[*]} ${args_inst[*]} ${args_extra[*]}"

## db access file
export PGPASSFILE="${CONF_DIR}/pgpass"

### setup ready
### -------------------------
### run selected mode

test $dry && echo "DRY RUN!"

## set and activate virtualenv
VENV="${WD}/venv"
source ${VENV}/bin/activate

## compose command according to mode
cmds=""
case $mode in
    run|run-config)
	background=1
	if [ -f $PID_FILE ]; then
	    PID=`cat $PID_FILE`
	    echo -e "This instance is maybe running (pid: $PID)...\n"
	    exit 1
	fi

	if [ $mode == "run-config" ]; then
	    ARGS="--config=$CONF_DIR/odoo.conf ${args_extra[*]}"
	fi

	if [ $config ]; then
	    ARGS="${args_extra[*]}"
	fi

	cmds+="python $ODOO $ARGS"
	    
	# store command
	if [ -z $dry ]; then
	    echo "$cmd" > "$RUNTIME_DIR/odoo_cmd"
	fi
	;;
    systemd-start)
	if [ -f $PID_FILE ]; then
	    PID=`cat $PID_FILE`
	    cmds+="kill ${PID}|"
	fi

	ARGS="--config=$CONF_DIR/odoo.conf"

	cmds+="python $ODOO $ARGS"
	;;
    stop|restart)
	if [ -f $PID_FILE ]; then 
	    PID=`cat $PID_FILE`
	    cmds+="kill ${PID}"
	else
	    echo -e "$PID_FILE not exist, maybe this instance is not running...\n"
	    exit 1
	fi
	if [ $mode == "restart" ]; then
	    restart=1
	fi	
	;;
    init)
	# stop instance before executing
	if [ -f $PID_FILE ]; then
	    PID=`cat $PID_FILE`
	    cmds+="kill ${PID}|"
	fi

	init_args=(
	    "--init=base"
	    "--without-demo"
	    "--log-level=info"
	    #"--stop-after-init" doesn't work...
	)
	cmds+="python $ODOO $ARGS ${init_args[*]} & stop_after_init"
	;;
    save)
	# stop instance before executing
	if [ -f $PID_FILE ]; then
	    PID=`cat $PID_FILE`
	    cmds+="kill ${PID}|"
	fi

	init_args=(
	    "-s -c $CONF_DIR/odoo.conf"
	    "--stop-after-init"
	)
	cmds+="python $ODOO $ARGS ${init_args[*]}"
	;;
    shell)
	# cli arguments for shell
	# assamble args
	ARGS="${args_inst_minimal[*]}"

	# compose command
	cmds+="python $ODOO shell $ARGS"
	;;
    update)
	# assamble args
	update_args=(
	    "--stop-after-init"
	    "--update"
	)
	ARGS="${args_inst_minimal[*]} ${update_args[@]} ${args_extra[@]::1}"

	# compose command
	cmds+="python $ODOO $ARGS"
	;;
    scaffold)
	# assamble args
	ARGS="scaffold ${args_extra[*]}"

	# compose command
	cmds+="python $ODOO $ARGS"
	;;
    dbdump)
	# pg_dump options:
	# -d, --dbname=DBNAME      database to dump
	# --role=ROLENAME          do SET ROLE before dump
	cmds+="pg_dump $DB_CONN -d $DB_NAME > ${DATA_DIR}/dump.sql"
	;;
    dbrestore)
	cmds+="psql $DB_CONN $DB_NAME -f ${DATA_DIR}/dump.sql"
	# cmds+="pg_restore $DB_CONN -d $INST ${DATA_DIR}/dump.sql"
	;;
    dropdb)
	# dropdb [OPTION]... DBNAME
	# options:
	# --maintenance-db=DBNAME   alternate maintenance database

	# stop instance before executing
	if [ -f $PID_FILE ]; then
	    PID=`cat $PID_FILE`
	    cmds+="kill ${PID}|"
	fi

	cmds+="dropdb $DB_CONN $DB_NAME"
	;;
    psql)
	cmds+="psql $DB_CONN $DB_NAME"
	;;
    link)
	module_path="${PWD}/${args_extra[@]::1}"
	module_name=`basename ${module_path}`
	module_link="${DATA_DIR}/addons/${VERSION}/${module_name}"
	if [[ ! -f "${module_path}/__manifest__.py" ]]; then
	    echo -e "${module_path} is not a valid module\n"
	    exit 1
	elif [[ -L $module_link ]]; then
	    echo -e "module already linked!\n"
	    exit 1
	fi
	
	cmds+="ln -s ${module_path} ${module_link}"
	;;
    unlink)
	module_path=${args_extra[@]::1}
	module_name=`basename ${module_path}`
	module_link="${DATA_DIR}/addons/${VERSION}/${module_name}"
	if [[ -L $module_link ]]; then
	    cmds+="rm ${module_link}"
	else
	    echo -e "${module_link} not exist!\n"
	    exit 1
	fi
	;;
    less)
	cmds+="less ${LOG_FILE}"
	;;
esac

# restart mode
CMD_FILE=${RUNTIME_DIR}/odoo_cmd
if [[ $restart && -f $CMD_FILE ]]; then
    background=1
    cmd_orig=`cat $CMD_FILE`
    cmds="${cmds}|${cmd_orig}"
fi

## source external functions
source $WD/tools/stop-after-init.sh

## run or echo command
IFS='|'
cmd_list=($cmds)

i=0
last=${#cmd_list[*]}-1
while [ $i -le ${last} ]; do
    cmd="${cmd_list[$i]}"
    
    # echo
    if [[ $verbose ]]; then
	ii=$i; let "ii++"
	echo -e "\nExecuting command ${ii} of ${#cmd_list[*]}:"
	echo -e "${cmd}\n"
    fi

    # run if not dry
    if [ -z $dry ]; then
	if [ $i -eq ${last} ]; then
	    if [[ $background ]]; then
		cmd="${cmd_list[$last]} &"
	    else
		# here is the entrypoint
		exec $cmd
	    fi
	fi
	eval "$cmd"
    fi
    
    let "i++"
done

exit 0
