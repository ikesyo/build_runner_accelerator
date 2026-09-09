import 'package:json_annotation/json_annotation.dart';

part 'model_385.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model385 {
  const Model385({required this.id, required this.value});

  final int id;
  final String value;

  factory Model385.fromJson(Map<String, dynamic> json) =>
      _$Model385FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model385ToJson(this);
}
