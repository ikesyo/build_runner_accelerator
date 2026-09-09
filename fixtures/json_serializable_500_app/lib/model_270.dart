import 'package:json_annotation/json_annotation.dart';

part 'model_270.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model270 {
  const Model270({required this.id, required this.value});

  final int id;
  final String value;

  factory Model270.fromJson(Map<String, dynamic> json) =>
      _$Model270FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model270ToJson(this);
}
