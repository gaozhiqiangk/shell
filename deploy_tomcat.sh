#!/bin/bash

#echo $USER
#pwd

# 定义代码名称与版本号
AppName=myapp
Version=`date "+%Y-%m-%d-%H-%M-%S"`

# 定义tomcat服务器IP地址、负载均衡器IP与浮动VIP
#TCIP='192.168.10.5 192.168.10.6'
LBIP='192.168.10.3
192.168.10.4'
VIP='172.18.100.100'

# 执行代码的用户身份
RunUser=tomcat
cd /home/tomcat

# 定义目标服务器代码路径
TCPath=/data/webapps

# 定义haproxy的backend的名字
BackendName=tcsrvs

TCGroup=$2
# 定义灰度发布的主机
TomcatGroup(){
	TCGroup=$1
	if [[ $TCGroup == 'pre-test' ]]; then
		TCIP='192.168.10.5'
	elif [[ $TCGroup == 'online-group1' ]]; then
		TCIP='192.168.10.6'
	elif [[ $TCGroup == 'online-group2' ]]; then
		TCIP='192.168.10.7 192.168.10.8'
	elif [[ $TCGroup == 'online-groupall' ]]; then
		TCIP='192.168.10.9 192.168.10.10 192.168.10.11'
	fi
}

FileDown(){
	# 拉取代码和打包
	#mkdir -v test`echo $RANDOM` | grep -o 'test[0-9]\+'
	#mv -v test  test`echo $RANDOM` | grep -o 'test[0-9]\+'

	echo '从gitlab上拉取源代码'
	# 拉取源代码并修改目录名称
	# 如果不是预发布就不用拉取代码了,只有是预发布才需要拉取代码
	if [[ $TCGroup == 'pre-test' ]]; then
		git clone git@gitlab.solomonlinux.com:myappgroup/myapp.git
echo ----------		
		# 这是预发布的软件版本包的名字
		FullAppName=`mv -v ${AppName} ${AppName}-${Version} | grep -o "${AppName}-[0-9-]\+"`
		
		# 压缩源代码
		tar zcf ${FullAppName}.tar.gz ${FullAppName}
	fi

	# 这是预发布后版本包的名字
	FullAppName=`ls -lrt | grep myapp | tail -1 | awk '{print $NF}' | cut -d. -f1`
	
	# 定义如果没有全部发布完成不允许将目录删除
	if [[ $TCGroup == 'online-group1' ]]; then
		rm -rf ${FullAppName}
	fi
}

FileCopy(){
	# 复制代码与解压
	echo '将文件拷至tomcat服务器'
	
	# 定义未发布主机的数量,默认为0,如果有未发布的主机就+1
	#NoDeploy=0

	for TCNode in $TCIP; do
		# 将代码代码拷至目标服务器,解压缩并创建软连接
		FileStatus=`ssh ${RunUser}@${TCNode} "[ -d ${TCPath}/${FullAppName} ] && echo exist || echo noexist"`
		# 只有文件不存在我们才拷,否则就退出当前循环检查TomcatGroup内其他主机文件是否存在,存在连软连接都不创建了
		if [[ $FileStatus == 'noexist' ]]; then
			scp ${FullAppName}.tar.gz tomcat@${TCNode}:${TCPath}
			# 只要能够执行到这里就说明有未未发布完整的组,此时要重新发布,也是就是将该组所有主机重新拷代码摘负载停服务等一系列操作
			#let NoDeploy+=1
		else
			continue
		fi
		ssh ${RunUser}@${TCNode} "cd $TCPath && tar xf ${FullAppName}.tar.gz"
		ssh ${RunUser}@${TCNode} "cd ${TCPath} && rm -rf latest && ln -sv ${FullAppName} latest"
		ssh ${RunUser}@${TCNode} "cd ${TCPath} && rm -rf ${FullAppName}.tar.gz"
	done

	# 如果有未发布完的主机我就执行此操作,否则就退出脚本的执行,因为已经发布完了
	#if [ $NoDeploy -eq 0 ]; then
	#	echo "这个主机组(${TCGroup})"已经发过了,请不要重新发布
	#fi
}

TomcatStart(){
	echo '启动tomcat服务器'
	for TCNode in $TCIP; do
		ssh root@${TCNode} '/etc/rc.d/init.d/tomcat start'
		sleep 3
	done
}

TomcatStop(){
	echo '停止tomcat服务器'
	for TCNode in $TCIP; do
		ssh root@${TCNode} "/etc/rc.d/init.d/tomcat stop"
		sleep 3
	done
}

TomcatAdd(){
	echo '将tomcat服务器添加到负载'
	for TCNode in $TCIP; do
		TomcatCheck $TCNode
		if [ $? -eq 0 ]; then
			ssh root@$VIP "echo 'enable server ${BackendName}/${TCNode}' | socat stdio /var/lib/haproxy/stats"
		fi
	done
}

TomcatDel(){
	echo '将tomcat服务器从负载摘除'
	for TCNode in $TCIP; do
		ssh root@$VIP "echo 'disable server ${BackendName}/${TCNode}' | socat stdio /var/lib/haproxy/stats"
	done
}

TomcatCheck(){
	TCNode=$1
	echo '检查tomcat服务器能否正常访问'
	Status=`curl -s -o /dev/null -w %{http_code} -I http://${TCNode}:8080/index.html`
	if [ $Status -eq 200 ]; then
		echo "tomcat服务器能正常访问"
		return 0
	else
		echo "tomcat服务器不能正常访问"
		return 1
	fi
}

TomcatRoll() {
	# 指定回滚到之前的几个版本,是上一个版本,还是上两个版本
	#VersionNum={$1:-1}

	for TCNode in $TCIP; do
		# 获取当前软件版本
		AppCurrentVersion=`ssh ${RunUser}@${TCNode} "ls -lrt ${TCPath} | grep myapp | tail -1 | awk -F '->' '{print \\$NF}'"`
		# 获取上一个软件版本
		AppLastVersion=`ssh ${RunUser}@${TCNode} "ls -lrt ${TCPath} | grep -B 1  ${AppCurrentVersion} | head -1 | awk '{print \\$NF}'"`
		
		# 删除和创建软连接
		ssh ${RunUser}@${TCNode} "cd ${TCPath} &&  rm -rf latest && mv ${AppCurrentVersion} /tmp && ln -sv ${AppLastVersion} latest"
	done
}

Help(){
	echo '获取帮助信息'
	echo 'Usage: `basename $0` {deploy|roll}'
}

main(){
	# 定义发布还是回滚
	Action=$1
	# 发布是发布第几组,pre-test,online-group1,online-group2,online-groupall
	TCGroup=$2

	case $Action in
		deploy)
			echo "部署"
			TomcatGroup $TCGroup
			FileDown
			TomcatDel
			TomcatStop
			FileCopy
			TomcatStart
			TomcatAdd
			;;
		roll)
			echo '回滚到上一个版本'
			TomcatGroup $TCGroup
			TomcatDel
			TomcatStop
			TomcatRoll 1
			TomcatStart
			TomcatAdd
			;;
		*)
			echo '用法错误'
			Help
			;;
	esac
}
# $1为deploy或roll;$2为灰度发布的组pre-test或online-group1或online-group2
main $1 $2

#1\回滚到指定的版本2\预发布与其它发布保持版本一致,那么判断如果是预发布就就保留文件夹供其它发布判断,如果是all发布那就删除文件夹只保留压缩包
