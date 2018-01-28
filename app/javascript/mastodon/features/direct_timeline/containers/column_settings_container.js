import { connect } from 'react-redux';
import ColumnSettings from '../../community_timeline/components/column_settings';
import { changeSetting } from '../../../actions/settings';

const mapStateToProps = state => ({
  settings: state.getIn(['settings', 'direct']),
});

const mapDispatchToProps = dispatch => ({

  onChange (path, checked) {
    dispatch(changeSetting(['direct', ...path], checked));
  },

});

export default connect(mapStateToProps, mapDispatchToProps)(ColumnSettings);
