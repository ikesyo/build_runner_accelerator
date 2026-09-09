import 'package:json_annotation/json_annotation.dart';

part 'model_157.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model157 {
  const Model157({required this.id, required this.value});

  final int id;
  final String value;

  factory Model157.fromJson(Map<String, dynamic> json) =>
      _$Model157FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model157ToJson(this);
}
