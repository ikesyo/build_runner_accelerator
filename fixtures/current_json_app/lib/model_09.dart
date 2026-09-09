import 'package:json_annotation/json_annotation.dart';

part 'model_09.g.dart';

@JsonSerializable()
class Model09 {
  Model09({required this.id, required this.displayName});

  factory Model09.fromJson(Map<String, dynamic> json) =>
      _$Model09FromJson(json);

  final int id;
  final String displayName;

  Map<String, dynamic> toJson() => _$Model09ToJson(this);
}

// baseline-marker: base
