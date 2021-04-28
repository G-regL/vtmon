dashboards=$(curl -su admin:admin 'http://142.135.212.32/api/search?type=dash-db')
x=1
while [ $x -lt `echo $dashboards | jq '. | length'` ]
do
  f_title=`echo $dashboards | jq -r ".[$x].folderTitle"`
  f_uid=`echo $dashboards | jq -r ".[$x].folderUid"`
  d_title=`echo $dashboards | jq -r ".[$x].title"`
  d_uid=`echo $dashboards | jq -r ".[$x].uid"`
  if [ "$f_title" == "test" ]; then x=$(( $x + 1 )); continue; fi
  json_path="res/grafana/$f_title-$f_uid/$d_title---$d_uid.json"
  echo $json_path
  echo '{"folderId": 0, "overwrite": true, "dashboard": ' > "$json_path"
  curl -su admin:admin 'http://142.135.212.32/api/dashboards/uid/'$d_uid | jq '.dashboard' >> "$json_path"
  echo '}' >> "$json_path"
  x=$(( $x + 1 ))
done