import 'package:json_annotation/json_annotation.dart';

part 'model_036.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model036 {
  const Model036({required this.id, required this.value});

  final int id;
  final String value;

  factory Model036.fromJson(Map<String, dynamic> json) =>
      _$Model036FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model036ToJson(this);
}
