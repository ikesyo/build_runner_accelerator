import 'package:json_annotation/json_annotation.dart';

part 'model_028.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model028 {
  const Model028({required this.id, required this.value});

  final int id;
  final String value;

  factory Model028.fromJson(Map<String, dynamic> json) =>
      _$Model028FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model028ToJson(this);
}
