import 'package:json_annotation/json_annotation.dart';

part 'model_241.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model241 {
  const Model241({required this.id, required this.value});

  final int id;
  final String value;

  factory Model241.fromJson(Map<String, dynamic> json) =>
      _$Model241FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model241ToJson(this);
}
