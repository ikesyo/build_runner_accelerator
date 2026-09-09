import 'package:json_annotation/json_annotation.dart';

part 'model_287.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model287 {
  const Model287({required this.id, required this.value});

  final int id;
  final String value;

  factory Model287.fromJson(Map<String, dynamic> json) =>
      _$Model287FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model287ToJson(this);
}
