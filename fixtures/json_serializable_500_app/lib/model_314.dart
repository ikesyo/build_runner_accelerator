import 'package:json_annotation/json_annotation.dart';

part 'model_314.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model314 {
  const Model314({required this.id, required this.value});

  final int id;
  final String value;

  factory Model314.fromJson(Map<String, dynamic> json) =>
      _$Model314FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model314ToJson(this);
}
