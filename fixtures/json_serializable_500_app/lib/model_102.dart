import 'package:json_annotation/json_annotation.dart';

part 'model_102.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model102 {
  const Model102({required this.id, required this.value});

  final int id;
  final String value;

  factory Model102.fromJson(Map<String, dynamic> json) =>
      _$Model102FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model102ToJson(this);
}
